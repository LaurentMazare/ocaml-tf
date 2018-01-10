open Base
open Tf_core

type 'a t =
  { op : [ `resource ] Ops.t
  ; type_ : 'a Operation.Type.t
  }

let context = Op.default_context ()

let variable ~shape ?(container="") ?(shared_name="") () =
  let type_ = Operation.Type.Resource in
  Op.create context (Op.Name.of_string "VarHandleOp")
    []
    [ "dtype", `type_ (Operation.Type.(to_data_type (P type_)))
    ; "shape", `shape shape
    ; "container", `string container
    ; "shared_name", `string shared_name
    ]
  |> fun op -> Op.execute1 op type_

let assign t value =
  Op.create context (Op.Name.of_string "AssignVariableOp")
    [Op.Tensor_handle.P t.op; Op.Tensor_handle.P value]
    [ "dtype", `type_ (Op.Tensor_handle.data_type value) ]
  |> Op.execute0

let create initial_value =
  let op = variable ~shape:(Op.Tensor_handle.dims initial_value) () in
  let t = { op; type_ = Op.Tensor_handle.type_ initial_value } in
  assign t initial_value;
  t

let read t =
  Op.create context (Op.Name.of_string "ReadVariableOp")
    [Op.Tensor_handle.P t.op]
    [ "dtype", `type_ (Operation.Type.(to_data_type (P t.type_)))]
  |> fun op -> Op.execute1 op t.type_

let resource t = t.op
