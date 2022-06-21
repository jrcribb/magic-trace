open! Core
open! Import

let saturating_sub_i64 a b =
  match Int64.(to_int (a - b)) with
  | None -> Int.max_value
  | Some offset -> offset
;;

let int64_of_hex_string str =
  (* Bit hacks for fast parsing of hex strings.
   *
   * Note that in ASCII, ('1' | 'a' | 'A') & 0xF = 1.
   *
   * So for each character, take the bottom 4 bits, and add 9 if it's
   * not a digit. *)
  let res = ref 0L in
  for i = 0 to String.length str - 1 do
    let open Int64 in
    let c = of_int (Char.to_int (String.unsafe_get str i)) in
    res := (!res lsl 4) lor ((c land 0xFL) + ((c lsr 6) lor ((c lsr 3) land 0x8L)))
  done;
  !res
;;

let%test_module _ =
  (module struct
    open Core

    let check str = Core.print_s ([%sexp_of: Int64.Hex.t] (int64_of_hex_string str))

    let%expect_test "int64 hex parsing" =
      check "fF";
      [%expect {| 0xff |}];
      check "f0f";
      [%expect {| 0xf0f |}];
      check "fA0f";
      [%expect {| 0xfa0f |}];
      check "0";
      [%expect {| 0x0 |}]
    ;;
  end)
;;

let ok_perf_line_re =
  Re.Perl.re
    {|^ *([0-9]+)/([0-9]+) +([0-9]+).([0-9]+): +(call|return|tr strt|syscall|sysret|hw int|iret|tr end|tr strt tr end|tr end  (?:call|return|syscall|sysret|iret)|jmp|jcc) +([0-9a-f]+) (.*) => +([0-9a-f]+) (.*)$|}
  |> Re.compile
;;

(* This matches exactly the power events which contain either [cbr] or [psb offs]. *)
let ok_perf_power_line_re =
  Re.Perl.re
    {|^ *([0-9]+)/([0-9]+) +([0-9]+).([0-9]+): +([a-z]*)? +(cbr|psb offs): ([0-9]+ freq: ([0-9]+) MHz)?(.*)$|}
  |> Re.compile
;;

let trace_error_re =
  Re.Posix.re
    {|^ instruction trace error type [0-9]+ (time ([0-9]+)\.([0-9]+) )?cpu [\-0-9]+ pid ([\-0-9]+) tid ([\-0-9]+) ip (0x[0-9a-fA-F]+|0) code [0-9]+: (.*)$|}
  |> Re.compile
;;

let symbol_and_offset_re = Re.Perl.re {|^(.*)\+(0x[0-9a-f]+)\s+\(.*\)$|} |> Re.compile
let unknown_symbol_dso_re = Re.Perl.re {|^\[unknown\]\s+\((.*)\)|} |> Re.compile

type classification =
  | Trace_error
  | Ok_perf_line
  | Ok_perf_power_line

let classify line =
  if String.is_prefix line ~prefix:" instruction trace error"
  then Re.Group.all (Re.exec trace_error_re line), Trace_error
  else (
    try Re.Group.all (Re.exec ok_perf_line_re line), Ok_perf_line with
    | _ -> Re.Group.all (Re.exec ok_perf_power_line_re line), Ok_perf_power_line)
;;

let parse_time ~time_hi ~time_lo =
  let time_lo =
    (* In practice, [time_lo] seems to always be 9 decimal places, but it seems
       good to guard against other possibilities. *)
    let num_decimal_places = String.length time_lo in
    match Ordering.of_int (Int.compare num_decimal_places 9) with
    | Less -> Int.of_string time_lo * Int.pow 10 (9 - num_decimal_places)
    | Equal -> Int.of_string time_lo
    | Greater -> Int.of_string (String.prefix time_lo 9)
  in
  let time_hi = Int.of_string time_hi in
  time_lo + (time_hi * 1_000_000_000) |> Time_ns.Span.of_int_ns
;;

let maybe_pid_of_string = function
  | "0" -> None
  | pid -> Some (Pid.of_string pid)
;;

let trace_error_to_event matches : Event.Decode_error.t =
  match matches with
  | [| _; _; time_hi; time_lo; pid; tid; ip; message |] ->
    let pid = maybe_pid_of_string pid in
    let tid = maybe_pid_of_string tid in
    let instruction_pointer =
      if String.( = ) ip "0" then None else Some (Int64.Hex.of_string ip)
    in
    let time =
      if String.is_empty time_hi && String.is_empty time_lo
      then Time_ns_unix.Span.Option.none
      else Time_ns_unix.Span.Option.some (parse_time ~time_hi ~time_lo)
    in
    { thread = { pid; tid }; instruction_pointer; message; time }
  | results ->
    raise_s
      [%message
        "Regex of trace error did not match expected fields" (results : string array)]
;;

let ok_perf_power_line_to_event matches : Event.Ok.t option =
  match matches with
  | [| _; pid; tid; time_hi; time_lo; _; kind; _; freq; _ |] ->
    let pid = maybe_pid_of_string pid in
    let tid = maybe_pid_of_string tid in
    let time = parse_time ~time_hi ~time_lo in
    (match kind with
    | "cbr" ->
      (* cbr (core-to-bus ratio) are events which show frequency changes. *)
      Some (Power { thread = { pid; tid }; time; freq = Int.of_string freq })
    | "psb offs" ->
      (* Ignore psb (packet stream boundary) packets *)
      None
    | _ -> raise_s [%message "Saw unexpected power event" (matches : string array)])
  | results ->
    raise_s
      [%message
        "Regex of perf power event did not match expected fields" (results : string array)]
;;

let ok_perf_line_to_event ?perf_maps matches line : Event.Ok.t =
  match matches with
  | [| _
     ; pid
     ; tid
     ; time_hi
     ; time_lo
     ; kind
     ; src_instruction_pointer
     ; src_symbol_and_offset
     ; dst_instruction_pointer
     ; dst_symbol_and_offset
    |] ->
    let pid = Int.of_string pid in
    let tid = Int.of_string tid in
    let time = parse_time ~time_hi ~time_lo in
    let src_instruction_pointer = int64_of_hex_string src_instruction_pointer in
    let dst_instruction_pointer = int64_of_hex_string dst_instruction_pointer in
    let parse_symbol_and_offset str ~addr =
      match Re.Group.all (Re.exec symbol_and_offset_re str) with
      | [| _; symbol; offset |] -> Symbol.From_perf symbol, Int.Hex.of_string offset
      | _ | (exception _) ->
        let failed = Symbol.Unknown, 0 in
        (match perf_maps with
        | None ->
          (match Re.Group.all (Re.exec unknown_symbol_dso_re str) with
          | [| _; dso |] ->
            (* CR-someday tbrindus: ideally, we would subtract the DSO base
               offset from [offset] here. *)
            Symbol.From_perf [%string "[unknown @ %{addr#Int64.Hex} (%{dso})]"], 0
          | _ | (exception _) -> failed)
        | Some perf_map ->
          (match Perf_map.Table.symbol ~pid:(Pid.of_int pid) perf_map ~addr with
          | None -> failed
          | Some location ->
            (* It's strange that perf isn't resolving these symbols. It says on
               the tin that it supports perf map files! *)
            let offset = saturating_sub_i64 addr location.start_addr in
            From_perf_map location, offset))
    in
    let src_symbol, src_symbol_offset =
      parse_symbol_and_offset src_symbol_and_offset ~addr:src_instruction_pointer
    in
    let dst_symbol, dst_symbol_offset =
      parse_symbol_and_offset dst_symbol_and_offset ~addr:dst_instruction_pointer
    in
    let starts_trace, kind =
      match String.chop_prefix kind ~prefix:"tr strt" with
      | None -> false, kind
      | Some rest -> true, String.lstrip ~drop:Char.is_whitespace rest
    in
    let ends_trace, kind =
      match String.chop_prefix kind ~prefix:"tr end" with
      | None -> false, kind
      | Some rest -> true, String.lstrip ~drop:Char.is_whitespace rest
    in
    let trace_state_change : Trace_state_change.t option =
      match starts_trace, ends_trace with
      | true, false -> Some Start
      | false, true -> Some End
      | false, false
      (* "tr strt tr end" happens when someone `go run`s ./demo/demo.go. But
         that trace is pretty broken for other reasons, so it's hard to say if
         this is truly necessary. Regardless, it's slightly more user friendly
         to show a broken trace instead of crashing here. *)
      | true, true -> None
    in
    let kind : Event.Kind.t option =
      match String.strip kind with
      | "call" -> Some Call
      | "return" -> Some Return
      | "jmp" -> Some Jump
      | "jcc" -> Some Jump
      | "syscall" -> Some Syscall
      | "hw int" -> Some Hardware_interrupt
      | "iret" -> Some Iret
      | "sysret" -> Some Sysret
      | "" -> None
      | _ ->
        printf "Warning: skipping unrecognized perf output: %s\n%!" line;
        None
    in
    Trace
      { thread =
          { pid = (if pid = 0 then None else Some (Pid.of_int pid))
          ; tid = (if tid = 0 then None else Some (Pid.of_int tid))
          }
      ; time
      ; trace_state_change
      ; kind
      ; src =
          { instruction_pointer = src_instruction_pointer
          ; symbol = src_symbol
          ; symbol_offset = src_symbol_offset
          }
      ; dst =
          { instruction_pointer = dst_instruction_pointer
          ; symbol = dst_symbol
          ; symbol_offset = dst_symbol_offset
          }
      }
  | results ->
    raise_s
      [%message "Regex of expected perf output did not match." (results : string array)]
;;

let to_event ?perf_maps line : Event.t option =
  try
    match classify line with
    | matches, Trace_error -> Some (Error (trace_error_to_event matches))
    | matches, Ok_perf_line -> Some (Ok (ok_perf_line_to_event matches ?perf_maps line))
    | matches, Ok_perf_power_line ->
      ok_perf_power_line_to_event matches |> Option.map ~f:(fun event -> Ok event)
  with
  | exn ->
    raise_s
      [%message
        "BUG: exception raised while parsing perf output. Please report this to \
         https://github.com/janestreet/magic-trace/issues/"
          (exn : exn)
          ~perf_output:(line : string)]
;;

let%test_module _ =
  (module struct
    open Core

    let check s = to_event s |> [%sexp_of: Event.t option] |> print_s

    let%expect_test "C symbol" =
      check
        {| 25375/25375 4509191.343298468:   call                     7f6fce0b71f4 __clock_gettime+0x24 (foo.so) =>     7ffd193838e0 __vdso_clock_gettime+0x0 (foo.so)|};
      [%expect
        {|
          ((Ok
            (Trace
             ((thread ((pid (25375)) (tid (25375)))) (time 52d4h33m11.343298468s)
              (kind Call)
              (src
               ((instruction_pointer 0x7f6fce0b71f4)
                (symbol (From_perf __clock_gettime)) (symbol_offset 0x24)))
              (dst
               ((instruction_pointer 0x7ffd193838e0)
                (symbol (From_perf __vdso_clock_gettime)) (symbol_offset 0x0))))))) |}]
    ;;

    let%expect_test "C symbol trace start" =
      check
        {| 25375/25375 4509191.343298468:   tr strt                             0 [unknown] (foo.so) =>     7f6fce0b71d0 __clock_gettime+0x0 (foo.so)|};
      [%expect
        {|
          ((Ok
            (Trace
             ((thread ((pid (25375)) (tid (25375)))) (time 52d4h33m11.343298468s)
              (trace_state_change Start)
              (src
               ((instruction_pointer 0x0)
                (symbol (From_perf "[unknown @ 0x0 (foo.so)]")) (symbol_offset 0x0)))
              (dst
               ((instruction_pointer 0x7f6fce0b71d0)
                (symbol (From_perf __clock_gettime)) (symbol_offset 0x0))))))) |}]
    ;;

    let%expect_test "C++ symbol" =
      check
        {| 7166/7166  4512623.871133092:   call                           9bc6db a::B<a::C, a::D<a::E>, a::F, a::F, G::H, a::I>::run+0x1eb (foo.so) =>           9f68b0 J::K<int, std::string>+0x0 (foo.so)|};
      [%expect
        {|
          ((Ok
            (Trace
             ((thread ((pid (7166)) (tid (7166)))) (time 52d5h30m23.871133092s)
              (kind Call)
              (src
               ((instruction_pointer 0x9bc6db)
                (symbol
                 (From_perf "a::B<a::C, a::D<a::E>, a::F, a::F, G::H, a::I>::run"))
                (symbol_offset 0x1eb)))
              (dst
               ((instruction_pointer 0x9f68b0)
                (symbol (From_perf "J::K<int, std::string>")) (symbol_offset 0x0))))))) |}]
    ;;

    let%expect_test "OCaml symbol" =
      check
        {|2017001/2017001 761439.053336670:   call                     56234f77576b Base.Comparable.=_2352+0xb (foo.so) =>     56234f4bc7a0 caml_apply2+0x0 (foo.so)|};
      [%expect
        {|
          ((Ok
            (Trace
             ((thread ((pid (2017001)) (tid (2017001)))) (time 8d19h30m39.05333667s)
              (kind Call)
              (src
               ((instruction_pointer 0x56234f77576b)
                (symbol (From_perf Base.Comparable.=_2352)) (symbol_offset 0xb)))
              (dst
               ((instruction_pointer 0x56234f4bc7a0) (symbol (From_perf caml_apply2))
                (symbol_offset 0x0))))))) |}]
    ;;

    (* CR-someday wduff: Leaving this concrete example here for when we support this. See my
       comment above as well.

       {[
         let%expect_test "Unknown Go symbol" =
         check
             {|2118573/2118573 770614.599007116:   tr strt tr end                      0 [unknown] (foo.so) =>           4591e1 [unknown] (foo.so)|};
           [%expect]
         ;;
       ]}
      *)

    let%expect_test "manufactured example 1" =
      check
        {|2017001/2017001 761439.053336670:   call                     56234f77576b x => +0xb (foo.so) =>     56234f4bc7a0 caml_apply2+0x0 (foo.so)|};
      [%expect
        {|
          ((Ok
            (Trace
             ((thread ((pid (2017001)) (tid (2017001)))) (time 8d19h30m39.05333667s)
              (kind Call)
              (src
               ((instruction_pointer 0x56234f77576b) (symbol (From_perf "x => "))
                (symbol_offset 0xb)))
              (dst
               ((instruction_pointer 0x56234f4bc7a0) (symbol (From_perf caml_apply2))
                (symbol_offset 0x0))))))) |}]
    ;;

    let%expect_test "manufactured example 2" =
      check
        {|2017001/2017001 761439.053336670:   call                     56234f77576b x => +0xb (foo.so) =>     56234f4bc7a0 => +0x0 (foo.so)|};
      [%expect
        {|
          ((Ok
            (Trace
             ((thread ((pid (2017001)) (tid (2017001)))) (time 8d19h30m39.05333667s)
              (kind Call)
              (src
               ((instruction_pointer 0x56234f77576b) (symbol (From_perf "x => "))
                (symbol_offset 0xb)))
              (dst
               ((instruction_pointer 0x56234f4bc7a0) (symbol (From_perf "=> "))
                (symbol_offset 0x0))))))) |}]
    ;;

    let%expect_test "manufactured example 3" =
      check
        {|2017001/2017001 761439.053336670:   call                     56234f77576b + +0xb (foo.so) =>     56234f4bc7a0 caml_apply2+0x0 (foo.so)|};
      [%expect
        {|
          ((Ok
            (Trace
             ((thread ((pid (2017001)) (tid (2017001)))) (time 8d19h30m39.05333667s)
              (kind Call)
              (src
               ((instruction_pointer 0x56234f77576b) (symbol (From_perf "+ "))
                (symbol_offset 0xb)))
              (dst
               ((instruction_pointer 0x56234f4bc7a0) (symbol (From_perf caml_apply2))
                (symbol_offset 0x0))))))) |}]
    ;;

    let%expect_test "unknown symbol in DSO" =
      check
        {|2017001/2017001 761439.053336670:   call                     56234f77576b [unknown] (foo.so) =>     56234f4bc7a0 caml_apply2+0x0 (foo.so)|};
      [%expect
        {|
          ((Ok
            (Trace
             ((thread ((pid (2017001)) (tid (2017001)))) (time 8d19h30m39.05333667s)
              (kind Call)
              (src
               ((instruction_pointer 0x56234f77576b)
                (symbol (From_perf "[unknown @ 0x56234f77576b (foo.so)]"))
                (symbol_offset 0x0)))
              (dst
               ((instruction_pointer 0x56234f4bc7a0) (symbol (From_perf caml_apply2))
                (symbol_offset 0x0))))))) |}]
    ;;

    let%expect_test "DSO with spaces in it" =
      check
        {|2017001/2017001 761439.053336670:   call                     56234f77576b [unknown] (this is a spaced dso.so) =>     56234f4bc7a0 caml_apply2+0x0 (foo.so)|};
      [%expect
        {|
          ((Ok
            (Trace
             ((thread ((pid (2017001)) (tid (2017001)))) (time 8d19h30m39.05333667s)
              (kind Call)
              (src
               ((instruction_pointer 0x56234f77576b)
                (symbol
                 (From_perf "[unknown @ 0x56234f77576b (this is a spaced dso.so)]"))
                (symbol_offset 0x0)))
              (dst
               ((instruction_pointer 0x56234f4bc7a0) (symbol (From_perf caml_apply2))
                (symbol_offset 0x0))))))) |}]
    ;;

    let%expect_test "decode error with a timestamp" =
      check
        " instruction trace error type 1 time 47170.086912826 cpu -1 pid 293415 tid \
         293415 ip 0x7ffff7327730 code 7: Overflow packet";
      [%expect
        {|
          ((Error
            ((thread ((pid (293415)) (tid (293415)))) (time (13h6m10.086912826s))
             (instruction_pointer (0x7ffff7327730)) (message "Overflow packet")))) |}]
    ;;

    let%expect_test "decode error without a timestamp" =
      check
        " instruction trace error type 1 cpu -1 pid 293415 tid 293415 ip 0x7ffff7327730 \
         code 7: Overflow packet";
      [%expect
        {|
          ((Error
            ((thread ((pid (293415)) (tid (293415)))) (time ())
             (instruction_pointer (0x7ffff7327730)) (message "Overflow packet")))) |}]
    ;;

    let%expect_test "lost trace data" =
      check
        " instruction trace error type 1 time 2651115.104731379 cpu -1 pid 1801680 tid \
         1801680 ip 0 code 8: Lost trace data";
      [%expect
        {|
          ((Error
            ((thread ((pid (1801680)) (tid (1801680)))) (time (30d16h25m15.104731379s))
             (instruction_pointer ()) (message "Lost trace data")))) |}]
    ;;

    let%expect_test "never-ending loop" =
      check
        " instruction trace error type 1 time 406036.830210719 cpu -1 pid 114362 tid \
         114362 ip 0xffffffffb0999ed5 code 10: Never-ending loop (refer perf config \
         intel-pt.max-loops)";
      [%expect
        {|
          ((Error
            ((thread ((pid (114362)) (tid (114362)))) (time (4d16h47m16.830210719s))
             (instruction_pointer (-0x4f66612b))
             (message "Never-ending loop (refer perf config intel-pt.max-loops)")))) |}]
    ;;

    let%expect_test "power event csb" =
      check
        "2937048/2937048 448556.689322817:                        cbr: 46 freq: 4606 MHz \
         (159%)                   0                0 [unknown] ([unknown])";
      [%expect
        {|
          ((Ok
            (Power
             ((thread ((pid (2937048)) (tid (2937048)))) (time 5d4h35m56.689322817s)
              (freq 4606))))) |}]
    ;;

    (* Expected [None] because we ignore these events currently. *)
    let%expect_test "power event psb offs" =
      check
        "2937048/2937048 448556.689403475:                        psb offs: \
         0x4be8                                0     7f068fbfd330 mmap64+0x50 \
         (/usr/lib64/ld-2.28.so)";
      [%expect {| () |}]
    ;;
  end)
;;