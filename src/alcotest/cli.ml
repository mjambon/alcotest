(*
 * Copyright (c) 2013-2016 Thomas Gazagnaire <thomas@gazagnaire.org>
 * Copyright (c) 2019 Craig Ferguson <me@craigfe.io>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Cmdliner
open Astring
module IntSet = Core.IntSet

module type S = sig
  include Core.S

  val run :
    (?argv:string array -> string -> unit test list -> return) with_options

  val run_with_args :
    (?argv:string array ->
    string ->
    'a Cmdliner.Term.t ->
    'a test list ->
    return)
    with_options
end

module Make (M : Monad.S) : S with type return = unit M.t = struct
  module C = Core.Make (M)
  include C

  let set_color style_renderer = Fmt_tty.setup_std_outputs ?style_renderer ()

  let set_color =
    let env = Arg.env_var "ALCOTEST_COLOR" in
    Term.(const set_color $ Fmt_cli.style_renderer ~env ())

  type runtime_options = {
    verbose : bool;
    compact : bool;
    tail_errors : [ `Unlimited | `Limit of int ] option;
    show_errors : bool;
    quick_only : bool;
    json : bool;
    log_dir : string option;
  }

  let v_runtime_flags ~defaults (`Verbose verbose) (`Compact compact)
      (`Tail_errors tail_errors) (`Show_errors show_errors)
      (`Quick_only quick_only) (`Json json) (`Log_dir log_dir) =
    let ( ||* ) a b = match (a, b) with Some a, _ -> Some a | None, b -> b in
    let verbose = verbose || defaults.verbose in
    let compact = compact || defaults.compact in
    let show_errors = show_errors || defaults.show_errors in
    let quick_only = quick_only || defaults.quick_only in
    let json = json || defaults.json in
    let log_dir = Some log_dir in
    let tail_errors = tail_errors ||* defaults.tail_errors in
    { verbose; compact; tail_errors; show_errors; quick_only; json; log_dir }

  let run_test ~and_exit
      { verbose; compact; tail_errors; show_errors; quick_only; json; log_dir }
      (`Test_filter filter) () tests name args =
    run_with_args ~and_exit ~verbose ~compact ?tail_errors ~quick_only
      ~show_errors ~json ?filter ?log_dir name tests args

  let json =
    let doc = "Display JSON for the results, to be used by a script." in
    Term.(app (const (fun x -> `Json x)))
      Arg.(value & flag & info [ "json" ] ~docv:"" ~doc)

  let log_dir =
    let fname_concat l = List.fold_left Filename.concat "" l in
    let default_dir = fname_concat [ Sys.getcwd (); "_build"; "_tests" ] in
    let doc = "Where to store the log files of the tests." in
    Term.(app (const (fun x -> `Log_dir x)))
      Arg.(value & opt dir default_dir & info [ "o" ] ~docv:"DIR" ~doc)

  let verbose =
    let env = Arg.env_var "ALCOTEST_VERBOSE" in
    let doc =
      "Display the test outputs. $(b,WARNING:) when using this option the \
       output logs will not be available for further inspection."
    in
    Term.(app (const (fun x -> `Verbose x)))
      Arg.(value & flag & info ~env [ "v"; "verbose" ] ~docv:"" ~doc)

  let compact =
    let env = Arg.env_var "ALCOTEST_COMPACT" in
    let doc = "Compact the output of the tests" in
    Term.(app (const (fun x -> `Compact x)))
      Arg.(value & flag & info ~env [ "c"; "compact" ] ~docv:"" ~doc)

  let limit_parser s =
    match s with
    | "unlimited" -> Ok `Unlimited
    | s -> (
        try
          let n = int_of_string s in
          if n < 0 then
            Error (`Msg "numeric limit must be nonnegative or 'unlimited'")
          else Ok (`Limit n)
        with Failure _ -> Error (`Msg "invalid numeric limit") )

  let limit_printer ppf limit =
    match limit with
    | `Unlimited -> Fmt.pf ppf "unlimited"
    | `Limit n -> Fmt.pf ppf "%i" n

  (* Parse/print a nonnegative number of lines or "unlimited". *)
  let limit = Cmdliner.Arg.conv (limit_parser, limit_printer)

  let tail_errors =
    let env = Arg.env_var "ALCOTEST_TAIL_ERRORS" in
    let doc =
      "Show only the last $(docv) lines of output in case of an error."
    in
    Term.(app (const (fun x -> `Tail_errors x)))
      Arg.(
        value
        & opt (some limit) None
        & info ~env [ "tail-errors" ] ~docv:"N" ~doc)

  let show_errors =
    let env = Arg.env_var "ALCOTEST_SHOW_ERRORS" in
    let doc = "Display the test errors." in
    Term.(app (const (fun x -> `Show_errors x)))
      Arg.(value & flag & info ~env [ "e"; "show-errors" ] ~docv:"" ~doc)

  let quick_only =
    let env = Arg.env_var "ALCOTEST_QUICK_TESTS" in
    let doc = "Run only the quick tests." in
    Term.(app (const (fun x -> `Quick_only x)))
      Arg.(value & flag & info ~env [ "q"; "quick-tests" ] ~docv:"" ~doc)

  let flags_with_defaults defaults =
    Term.(
      pure (v_runtime_flags ~defaults)
      $ verbose
      $ compact
      $ tail_errors
      $ show_errors
      $ quick_only
      $ json
      $ log_dir)

  let regex =
    let parse s =
      try Ok Re.(compile @@ Pcre.re s) with
      | Re.Perl.Parse_error -> Error (`Msg "Perl-compatible regexp parse error")
      | Re.Perl.Not_supported -> Error (`Msg "unsupported regexp feature")
    in
    let print = Re.pp_re in
    Arg.conv (parse, print)

  exception Invalid_format

  let int_range_list : IntSet.t Cmdliner.Arg.conv =
    let parse s =
      let set = ref IntSet.empty in
      let acc i = set := IntSet.add i !set in
      let ranges = String.cuts ~sep:"," s in
      let process_range s =
        let bounds = String.cuts ~sep:".." s |> List.map String.to_int in
        match bounds with
        | [ Some i ] -> acc i
        | [ Some lower; Some upper ] when lower <= upper ->
            for i = lower to upper do
              acc i
            done
        | _ -> raise Invalid_format
      in
      match List.iter process_range ranges with
      | () -> Ok !set
      | exception Invalid_format ->
          Error
            (`Msg "must be a comma-separated list of integers / integer ranges")
    in
    let print ppf set =
      Fmt.pf ppf "%a" Fmt.(braces @@ list ~sep:comma int) (IntSet.elements set)
    in
    Arg.conv (parse, print)

  let test_filter =
    let name_regex =
      let doc = "A regular expression matching the names of tests to run" in
      Arg.(value & pos 0 (some regex) None & info [] ~doc ~docv:"NAME_REGEX")
    in
    let number_filter =
      let doc =
        "A comma-separated list of test case numbers (and ranges of numbers) \
         to run, e.g: '4,6-10,19'"
      in
      Arg.(
        value
        & pos 1 (some int_range_list) None
        & info [] ~doc ~docv:"TESTCASES")
    in
    Term.(
      pure (fun n t -> `Test_filter (Some (n, t))) $ name_regex $ number_filter)

  let default_cmd ~and_exit runtime_flags args library_name tests =
    let exec_name = Filename.basename Sys.argv.(0) in
    let doc = "Run all the tests." in
    let flags = flags_with_defaults runtime_flags in
    ( Term.(
        pure (run_test ~and_exit)
        $ flags
        $ pure (`Test_filter None)
        $ set_color
        $ args
        $ pure library_name
        $ pure tests),
      Term.info exec_name ~doc )

  let test_cmd ~and_exit runtime_flags ~filter args library_name tests =
    let doc = "Run a subset of the tests." in
    let flags = flags_with_defaults runtime_flags in
    let filter =
      Term.(
        pure (fun a -> match a with `Test_filter None -> filter | _ -> a)
        $ test_filter)
    in
    ( Term.(
        pure (run_test ~and_exit)
        $ flags
        $ filter
        $ set_color
        $ args
        $ pure library_name
        $ pure tests),
      Term.info "test" ~doc )

  let list_cmd tests =
    let doc = "List all available tests." in
    ( Term.(pure (fun () -> list_tests) $ set_color $ pure tests),
      Term.info "list" ~doc )

  let run_with_args ?(and_exit = true) ?(verbose = false) ?(compact = false)
      ?tail_errors ?(quick_only = false) ?(show_errors = false) ?(json = false)
      ?filter ?log_dir ?argv name (args : 'a Term.t) (tl : 'a test list) =
    let runtime_flags =
      { verbose; compact; tail_errors; show_errors; quick_only; json; log_dir }
    in
    let choices =
      [
        list_cmd tl;
        test_cmd ~and_exit runtime_flags ~filter:(`Test_filter filter) args name
          tl;
      ]
    in
    match
      Term.eval_choice ?argv
        (default_cmd ~and_exit runtime_flags args name tl)
        choices
    with
    | `Ok im -> im
    | `Error _ -> raise Test_error
    | _ -> if and_exit then exit 0 else M.return ()

  let run ?and_exit ?verbose ?compact ?tail_errors ?quick_only ?show_errors
      ?json ?filter ?log_dir ?argv name tl =
    run_with_args ?and_exit ?verbose ?compact ?tail_errors ?quick_only
      ?show_errors ?json ?filter ?log_dir ?argv name (Term.pure ()) tl
end
