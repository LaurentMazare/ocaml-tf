open Base
module O = Tf_ops.Ops
module Th = Tf_ops.Op.Tensor_handle
module V = Tf_ops.Var

(* This should reach ~92% accuracy. *)
let image_dim = Helper.image_dim
let label_count = Helper.label_count
let epochs = 300

let () =
  let mnist_dataset = Helper.read_files () in
  let test_images = Helper.test_images mnist_dataset in
  let test_labels = Helper.test_labels mnist_dataset in

  let w = V.f32 [ image_dim; label_count ] 0. in
  let b = V.f32 [ label_count ] 0. in
  let model xs = O.(xs *^ V.read w + V.read b) |> O.softmax in
  for epoch = 1 to epochs do
    if epoch % 50 = 0 then begin
      let accuracy =
        O.(equal (arg_max (model test_images)) (arg_max test_labels))
        |> O.cast ~type_dstT:Float
        |> O.reduce_mean
        |> O.to_float
      in
      Stdio.printf "epoch %d, accuracy %.2f%%\n%!" epoch (100. *. accuracy)
    end;
    (* TODO: gradient descent.
      let cross_entropy = O.cross_entropy ~ys:ys_node ~y_hats:ys_ `mean in
     *)
  done