(**************************************************************************)
(*                                                                        *)
(*                        OCamlPro Typerex                                *)
(*                                                                        *)
(*   Copyright OCamlPro 2011-2016. All rights reserved.                   *)
(*   This file is distributed under the terms of the GPL v3.0             *)
(*   (GNU General Public Licence version 3.0).                            *)
(*                                                                        *)
(*     Contact: <typerex@ocamlpro.com> (http://www.ocamlpro.com/)         *)
(*                                                                        *)
(*  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,       *)
(*  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES       *)
(*  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND              *)
(*  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS   *)
(*  BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN    *)
(*  ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN     *)
(*  CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE      *)
(*  SOFTWARE.                                                             *)
(**************************************************************************)

open SimpleConfig

let ignored_files = Globals.Config.create_option
    ["ignored_files"]
    ~short_help:"Module to ignore during the lint."
    ["Module to ignore during the lint."]
    ~level:0
    (SimpleConfig.list_option SimpleConfig.string_option)
    []

let scan_project path = (* todo *)
  Format.printf "Scanning files in project %S...\n%!" path;
  let found_files =
    let files = ref [] in
    Utils.iter_files (fun file ->
        files := (Filename.concat path file) :: !files) path;
    !files in
  Format.printf "Found '%d' file(s)\n%!" (List.length found_files);
  found_files

let filter_plugins plugins =
  let activated_plugins = Hashtbl.create 42 in
  Plugin.iter_plugins (fun plugin checks ->
      let module P = (val plugin : Plugin_types.PLUGIN) in
      let option_names = P.short_name :: [ "disable" ] in
      let opt_value = Globals.Config.get_option_value option_names in
      if not (bool_of_string opt_value) 
      then Hashtbl.add activated_plugins plugin checks
    ) plugins;
  activated_plugins

let filter_modules sources ignore_files =
  List.filter (fun source ->
      not (List.exists (fun ignored -> ignored = source) ignore_files)) sources

let parse_source source =
  let tool_name = Ast_mapper.tool_name () in
  try
    Some
      (Pparse.parse_implementation ~tool_name Format.err_formatter  source)
  with Syntaxerr.Error _ ->
    Plugin_error.(print Format.err_formatter (Syntax_error source));
    None

let parse_interf source =
  let tool_name = Ast_mapper.tool_name () in
  try
    Some (Pparse.parse_interface ~tool_name Format.err_formatter source)
  with Syntaxerr.Error _ ->
    Plugin_error.(print Format.err_formatter (Syntax_error source));
    None

let is_source file = Filename.check_suffix file "ml"
let is_interface file = Filename.check_suffix file "mli"
let is_cmt file = Filename.check_suffix file "cmt"
let is_cmt file = Filename.check_suffix file "cmt"
let is_cmxs file = Filename.check_suffix file "cmxs"

let ( // ) = Filename.concat

let rec load_plugins list =
  List.iter (fun file ->
      try
        if Sys.is_directory file then begin
          let files = ref [] in
          Utils.iter_files (fun f ->
              files := (file // f) :: !files) file;
          load_plugins (List.filter is_cmxs !files)
        end
        else if Filename.check_suffix file "cmxs" then
          Dynlink.loadfile file
        else
          Printf.eprintf "Cannot load %S\n%!" file
      with _ ->
        Printf.eprintf "%S: No such file or directory.\n%!" file)
    list

let register_default_sempatch () =
  (* TODO: Fabrice: vérifier que le fichier existe, sinon prendre celui dans
     l'exécutable par défaut*)
  let
    module Default = Plugin_sempatch.SempatchPlugin.MakeLintPatch(struct
      let name = "Lint from semantic patches (default)"
      let short_name = "sempatch-lint"
      let details = "Lint from semantic patches (default)."
      let patches = Globals.default_patches
    end) in
  ()

let register_default_plugins patches =
  register_default_sempatch ();
  let
    module UserDefined = Plugin_sempatch.SempatchPlugin.MakeLintPatch(struct
      let name = "Lint from semantic patches (user defined)."
      let short_name = "sempatch-lint"
      let details = "Lint from semantic patches (user defined)."
      let patches = patches
    end) in
  ()

let output fmt plugins =
  (* TO REMOVE : just for testing fmtput *)
  Plugin.iter_plugins (fun plugin checks ->
      let module P = (val plugin : Plugin_types.PLUGIN) in

      Warning.iter
        (fun warning -> Warning.print fmt warning)
        P.warnings) plugins

let print plugins =
  output Format.err_formatter plugins

let to_text file plugins =
  let oc = open_out file in
  let fmt = Format.formatter_of_out_channel oc in
  output fmt plugins;
  close_out oc

let scan ?output_text patches path =
  (* XXX TODO : don't forget to read config file too ! *)
  let plugins = filter_plugins Globals.plugins in

  let all = filter_modules (scan_project path) !!ignored_files in

  (* All inputs for each analyze *)
  let mls = List.filter is_source all in
  let mlis = List.filter is_interface all in

  let cmts =
    let files = List.filter is_cmt all in
    List.map (fun file -> lazy (Cmt_format.read_cmt file)) files in

  let asts_ml, asts_mli =
    List.map (fun file -> lazy (parse_source file)) mls,
    List.map (fun file -> lazy (parse_interf file)) mlis in

  Format.printf "Starting analyses...\n%!";

  register_default_plugins patches;
  Parallel_engine.lint all mls mlis asts_ml asts_mli cmts plugins;

  (* TODO: do we want to print in stderr by default ? *)
  begin match output_text with
  | None -> print plugins
  | Some file -> to_text file plugins
  end;

  plugins
