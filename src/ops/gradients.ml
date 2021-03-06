open Base
module T = Op.Tensor_handle
module Type = Tf_core.Operation.Type

exception No_derivative_for_op of Op.Name.t

(* Return a table mapping 'useful node' names to the number of times they
   appear as input of other useful nodes.
   Nodes are useful in they are on a path between [node] and a leaf
   that contains only float/double nodes.
*)
let uses_per_id th =
  let uses_per_id = Hashtbl.create (module T.Id) () in
  let rec is_useful (T.P th) =
    let id = T.id th in
    let is_real =
      match T.type_ th with
      | Type.Float -> true
      | Type.Double -> true
      | _ -> false
    in
    let current_uses = Hashtbl.find uses_per_id id |> Option.value ~default:0 in
    if not is_real
    then false
    else
      match T.tape_info th with
      | `none -> false
      | `leaf _ ->
        Hashtbl.set uses_per_id ~key:id ~data:(1 + current_uses);
        true
      | `node tape_info ->
        let inputs = Op.Tape_info.inputs tape_info in
        (* The [is_useful] function should be applied recursively to children only once.
           It should also apply to all children, hence the List.map ... |> List.exists below.
        *)
        let is_useful =
          (  current_uses > 0
          || List.map inputs ~f:is_useful |> List.exists ~f:Fn.id)
        in
        if is_useful
        then begin
          Hashtbl.set uses_per_id ~key:id ~data:(1 + current_uses)
        end;
        is_useful
  in
  ignore (is_useful th : bool);
  uses_per_id

let aggregate_contributions = function
  | [] -> assert false
  | [ input ] -> input
  | (T.P input :: _) as inputs ->
    let type_ = T.type_ input in
    let inputs =
      List.map inputs ~f:(fun input -> Option.value_exn (T.unpack input type_))
    in
    match type_ with
    | Type.Double -> T.P (Ops.addN inputs)
    | Type.Float -> T.P (Ops.addN inputs)
    | _ -> failwith "Improper type."

let aggregate_contributions_multi gradients =
  List.map gradients ~f:(fun (output_idx, gradient) ->
    Option.value_exn output_idx, gradient)
  |> Map.of_alist_multi (module Int)
  |> Map.map ~f:aggregate_contributions

type var_and_gradient =
  | Float of [ `float ] T.var option * [ `float ] T.t
  | Double of [ `double ] T.var option * [ `double ] T.t

type t = (Op.Tensor_handle.Id.t, var_and_gradient) Hashtbl.t

(* Compute the gradients of [th] with respect to leafs using backpropagation.
   This only works when [th] is a scalar. *)
let compute th =
  let uses_per_id = uses_per_id (T.P th) in
  let contributions = Hashtbl.create (module T.Id) () in
  let t : (T.Id.t, var_and_gradient) Hashtbl.t = Hashtbl.create (module T.Id) () in
  let rec add_contribution (T.P th) ~gradient =
    let id = T.id th in
    match Hashtbl.find uses_per_id id with
    | None -> ()
    | Some uses ->
      assert (uses > 0);
      Option.iter gradient ~f:(fun gradient ->
        let output_idx =
          match T.tape_info th with
          | `none | `leaf _ -> None
          | `node tape_info -> Some (Op.Tape_info.output_idx tape_info)
        in
        Hashtbl.add_multi contributions ~key:id ~data:(output_idx, gradient));
      let uses = uses - 1 in
      Hashtbl.set uses_per_id ~key:id ~data:uses;
      if uses = 0
      then begin
        let gradients = Hashtbl.find contributions id in
        match T.tape_info th with
        | `none -> ()
        | `leaf maybe_var ->
          Option.iter gradients ~f:(fun gradients ->
            let T.P gradient = List.map gradients ~f:snd |> aggregate_contributions in
            match T.type_ th, T.type_ gradient with
            | Type.Float, Type.Float ->
              Hashtbl.add_exn t ~key:id ~data:(Float (maybe_var, gradient))
            | Type.Double, Type.Double ->
              Hashtbl.add_exn t ~key:id ~data:(Double (maybe_var, gradient))
            | _, _ -> assert false)
        | `node tape_info ->
          let op_name = Op.Tape_info.op_name tape_info in
          let inputs = Op.Tape_info.inputs tape_info in
          match gradients with
          | None ->
            List.iter inputs ~f:(add_contribution ~gradient:None)
          | Some gradients ->
            match Ops_gradients.find op_name with
            | None ->
              begin
                match Ops_gradients.find_multi op_name with
                | None -> raise (No_derivative_for_op op_name)
                | Some fn ->
                  let gradients = aggregate_contributions_multi gradients in
                  try
                    List.iter2_exn (fn ~self:(T.P th) ~gradients) inputs
                      ~f:(fun gradient input -> add_contribution input ~gradient)
                  with
                  | exn -> Exn.reraise exn (Op.Name.to_string op_name)
              end
            | Some fn ->
              try
                let gradients = List.map gradients ~f:snd in
                List.iter2_exn
                  (fn ~self:(T.P th) ~gradient:(aggregate_contributions gradients))
                  inputs
                  ~f:(fun gradient input -> add_contribution input ~gradient)
              with
              | exn -> Exn.reraise exn (Op.Name.to_string op_name)
      end
  in
  let one =
    T.P Ops.(fill (shape th ~type_out_type:Int32) (float 1. (T.type_ th)))
  in
  add_contribution (P th) ~gradient:(Some one);
  t

let apply_sgd_step t ~learning_rate =
  Hashtbl.iter t ~f:(function
    | Float (Some var, gradient) ->
      Var.assign var Ops.(Var.read var - f32 learning_rate * gradient)
    | Double (Some var, gradient) ->
      Var.assign var Ops.(Var.read var - f64 learning_rate * gradient)
    | Float (None, _) | Double (None, _) -> ()
  )
