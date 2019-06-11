(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Pyre
open Ast
open Expression
open Statement

type annotation_lookup = Type.t Location.Reference.Table.t

type definition_lookup = Location.Reference.t Location.Reference.Table.t

type t = {
  annotations_lookup: annotation_lookup;
  definitions_lookup: definition_lookup
}

(** The result state of this visitor is ignored. We need two read-only pieces of information to
    build the location table: the types resolved for this statement, and a reference to the
    (mutable) location table to update. *)
module ExpressionVisitor = struct
  type t = {
    pre_resolution: Resolution.t;
    post_resolution: Resolution.t;
    annotations_lookup: annotation_lookup;
    definitions_lookup: definition_lookup
  }

  let expression_base
      ~postcondition
      ({ pre_resolution; post_resolution; annotations_lookup; definitions_lookup } as state)
      expression
    =
    let resolution = if postcondition then post_resolution else pre_resolution in
    let resolve ~expression =
      try
        let annotation = Resolution.resolve resolution expression in
        if Type.is_top annotation || Type.is_unbound annotation then
          None
        else
          Some annotation
      with
      | TypeOrder.Untracked _ -> None
    in
    let resolve_definition ~expression =
      let find_definition reference =
        Resolution.global resolution reference
        >>| Node.location
        >>= fun location ->
        if Location.equal location Location.Reference.any then None else Some location
      in
      match Node.value expression with
      | Name (Name.Identifier identifier) -> find_definition (Reference.create identifier)
      | Name (Name.Attribute { base; attribute; _ } as name) -> (
          let definition = Reference.from_name name >>= find_definition in
          match definition with
          | Some definition -> Some definition
          | None ->
              (* Resolve prefix to check if this is a method. *)
              resolve ~expression:base
              >>| Type.class_name
              >>| (fun prefix -> Reference.create ~prefix attribute)
              >>= find_definition )
      | _ -> None
    in
    let store_lookup ~table ~location ~data =
      if
        (not (Location.equal location Location.Reference.any))
        && not (Location.equal location Location.Reference.synthetic)
      then
        Hashtbl.set table ~key:location ~data
    in
    let rec annotate_expression ({ Node.location; value } as expression) =
      let store_annotation location annotation =
        store_lookup ~table:annotations_lookup ~location ~data:annotation
      in
      let store_definition location data =
        store_lookup ~table:definitions_lookup ~location ~data
      in
      resolve ~expression >>| store_annotation location |> ignore;
      resolve_definition ~expression >>| store_definition location |> ignore;
      match value with
      | Call { callee; arguments } ->
          annotate_expression callee;
          let annotate_argument_name { Call.Argument.name; value = { Node.location; _ } as value } =
            match name, resolve ~expression:value with
            | Some { Node.location = { Location.start; _ }; _ }, Some annotation ->
                let location = { location with Location.start } in
                store_annotation location annotation
            | _ -> ()
          in
          List.iter ~f:annotate_argument_name arguments
      | Name (Name.Attribute { base; _ }) ->
          annotate_expression base;
          ()
      | _ -> ()
    in
    annotate_expression expression;
    state


  let expression state expression = expression_base ~postcondition:false state expression

  let expression_postcondition state expression =
    expression_base ~postcondition:true state expression


  let statement state _ = state
end

module Visit = struct
  include Visit.Make (ExpressionVisitor)

  let visit state source =
    let state = ref state in
    let visit_statement_override ~state ~visitor statement =
      let precondition_visit = visit_expression ~state ~visitor:ExpressionVisitor.expression in
      let postcondition_visit =
        visit_expression ~state ~visitor:ExpressionVisitor.expression_postcondition
      in
      match Node.value statement with
      | Assign { Assign.target; annotation; value; _ } ->
          postcondition_visit target;
          Option.iter ~f:precondition_visit annotation;
          precondition_visit value
      | Define { Define.body; _ } when not (List.is_empty body) ->
          (* No type info available for nested defines; they are analyzed on their own. *)
          ()
      | Define { Define.signature = { parameters; decorators; return_annotation; _ }; _ } ->
          let visit_parameter
              { Node.value = { Parameter.annotation; value; name }; location }
              ~visit_expression
            =
            Name (Name.Identifier name) |> Node.create ~location |> visit_expression;
            Option.iter ~f:visit_expression value;
            Option.iter ~f:visit_expression annotation
          in
          List.iter parameters ~f:(visit_parameter ~visit_expression:postcondition_visit);
          List.iter decorators ~f:postcondition_visit;
          Option.iter ~f:postcondition_visit return_annotation
      | _ -> visit_statement ~state ~visitor statement
    in
    List.iter
      ~f:(visit_statement_override ~state ~visitor:ExpressionVisitor.statement)
      source.Source.statements;
    !state
end

let create_of_source environment source =
  let annotations_lookup = Location.Reference.Table.create () in
  let definitions_lookup = Location.Reference.Table.create () in
  let walk_define
      ({ Node.value = { Define.signature = { name = caller; _ }; _ } as define; _ } as define_node)
    =
    let cfg = Cfg.create define in
    let annotation_lookup =
      ResolutionSharedMemory.get caller >>| Int.Map.of_tree |> Option.value ~default:Int.Map.empty
    in
    let walk_statement node_id statement_index statement =
      let pre_annotations, post_annotations =
        Map.find annotation_lookup ([%hash: int * int] (node_id, statement_index))
        >>| (fun { ResolutionSharedMemory.precondition; postcondition } ->
              Reference.Map.of_tree precondition, Reference.Map.of_tree postcondition)
        |> Option.value ~default:(Reference.Map.empty, Reference.Map.empty)
      in
      let pre_resolution = TypeCheck.resolution environment ~annotations:pre_annotations () in
      let post_resolution = TypeCheck.resolution environment ~annotations:post_annotations () in
      Visit.visit
        { ExpressionVisitor.pre_resolution;
          post_resolution;
          annotations_lookup;
          definitions_lookup
        }
        (Source.create [statement])
      |> ignore
    in
    let walk_cfg_node ~key:node_id ~data:cfg_node =
      let statements = Cfg.Node.statements cfg_node in
      List.iteri statements ~f:(walk_statement node_id)
    in
    Hashtbl.iteri cfg ~f:walk_cfg_node;

    (* Special-case define signature processing, since this is not included in the define's cfg. *)
    let define_signature = { define_node with value = Define { define with Define.body = [] } } in
    walk_statement Cfg.entry_index 0 define_signature
  in
  (* TODO(T31738631): remove include_toplevels *)
  Preprocessing.defines ~include_nested:true ~include_toplevels:true source
  |> List.iter ~f:walk_define;
  { annotations_lookup; definitions_lookup }


let get_best_location lookup_table ~position =
  let location_contains_position
      { Location.start = { Location.column = start_column; line = start_line };
        stop = { Location.column = stop_column; line = stop_line }
      ; _
      }
      { Location.column; line }
    =
    let start_ok = start_line < line || (start_line = line && start_column <= column) in
    let stop_ok = stop_line > line || (stop_line = line && stop_column > column) in
    start_ok && stop_ok
  in
  let weight
      { Location.start = { Location.column = start_column; line = start_line };
        stop = { Location.column = stop_column; line = stop_line }
      ; _
      }
    =
    ((stop_line - start_line) * 1000) + stop_column - start_column
  in
  Hashtbl.filter_keys lookup_table ~f:(fun key -> location_contains_position key position)
  |> Hashtbl.to_alist
  |> List.min_elt ~compare:(fun (location_left, _) (location_right, _) ->
         weight location_left - weight location_right)


let get_annotation { annotations_lookup; _ } ~position =
  let instantiate_location (location, annotation) =
    ( Location.instantiate ~lookup:(fun hash -> Ast.SharedMemory.Handles.get ~hash) location,
      annotation )
  in
  get_best_location annotations_lookup ~position >>| instantiate_location


let get_definition { definitions_lookup; _ } ~position =
  get_best_location definitions_lookup ~position
  >>| snd
  >>| Location.instantiate ~lookup:(fun hash -> Ast.SharedMemory.Handles.get ~hash)


let get_all_annotations { annotations_lookup; _ } =
  let instantiate_location (location, annotation) =
    ( Location.instantiate ~lookup:(fun hash -> Ast.SharedMemory.Handles.get ~hash) location,
      annotation )
  in
  Hashtbl.to_alist annotations_lookup |> List.map ~f:instantiate_location


let get_all_definitions { definitions_lookup; _ } = Hashtbl.to_alist definitions_lookup
