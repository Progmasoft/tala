// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <array>
#include <cstdint>
#include <llvm/Support/raw_ostream.h>
#include <span>
#include <string_view>

#include "ExecutionCases.hpp"
#include "Progmasoft/Tala/Runtime/AARC.hpp"
#include "Progmasoft/Tala/Support/CompilerStack.hpp"
#include "SourceFuzz.hpp"

// Executable regressions for the features whose tables are written by hand in
// this file: methods with inferred return types, evaluation by need,
// arguments passed by need, classic enums, closures with the runtime that
// owns them, and programs that own
// closures while control leaves through a block used as a value. Every
// program runs through CorePrep, Xpp, Xmm, LLVM and the ORC JIT, unoptimized
// and optimized, and must return its expected value from both.
//
// They are a program of their own, beside `source_execution_smoke` and
// `source_fuzz_smoke`, because each smoke program is a deterministic check
// under one process watchdog, and a watchdog is meant to end a run that
// never finishes, not to bound the size of a test table.

namespace
{
    // Programs that own closures while control leaves through a block used
    // as a value. The ownership-flow verifiers of Xpp and Xmm run on every
    // program compiled here, so a path that left without releasing what it
    // owns, or released it twice, is rejected. The two CorePrep lowerings
    // are compared on them as well. These are compiled and verified; the
    // table of closure cases below runs closures.
    constexpr std::array<std::string_view, 11U> kOwnershipCases{ {
        // An initializer that never completes, after a closure was created.
        "namespace Fuzz; class Program { "
        "public static int Step(_ int n) { return n > 0 ? 1 + Step(n - 1) "
        ": 0; } "
        "public static int Evaluate() { int a = Step(4); "
        "auto held = [kept = a] \\ -> kept; "
        "int r = if (held() > 3) { return held(); } else { return 0; }; "
        "return r; } }",
        // A do/while whose condition never completes, reached after the
        // body and after a continue, with a closure created in the body.
        "namespace Fuzz; class Program { "
        "public static int Step(_ int n) { return n > 0 ? 1 + Step(n - 1) "
        ": 0; } "
        "public static int Evaluate() { int a = Step(4); "
        "auto held = [kept = a] \\ -> kept; int n = 0; "
        "do { n += held(); auto inner = [seen = n] \\ -> seen + 1; "
        "if (inner() < 3) { continue; } } "
        "while (if (n > 6) { return n; } else { return 0 - n; }); "
        "return 0; } }",
        // Break and continue out of value blocks in nested loops, with
        // closures created in both loops.
        "namespace Fuzz; class Program { "
        "public static int Step(_ int n) { return n > 0 ? 1 + Step(n - 1) "
        ": 0; } "
        "public static int Evaluate() { int a = Step(4); int t = 0; "
        "for (int i = 0; i < a; i += 1) { "
        "auto step = [by = i] \\ -> by + 1; int j = 0; "
        "while (j < 3) { j += 1; auto pick = [at = j] \\ -> at; "
        "t += if (pick() == 2) { break; } else { step() }; } "
        "t += match (i) { 1 -> { continue; }, int n -> step() + n }; } "
        "return t; } }",
        // A value carried out of a value block to a loop expression, a
        // break in a loop condition and a continue in a loop update, each
        // with a closure alive at the transfer.
        "namespace Fuzz; class Program { "
        "public static int Step(_ int n) { return n > 0 ? 1 + Step(n - 1) "
        ": 0; } "
        "public static int Evaluate() { int a = Step(4); int t = 0; "
        "int found = while (true) { t += 1; "
        "auto seen = [at = t] \\ -> at * 2; "
        "int q = if (seen() > a) { break seen(); } else { 0 }; t += q; }; "
        "auto keep = [of = found] \\ -> of; int n = 0; "
        "while (if (n > keep()) { break; } else { true }) { n += 1; } "
        "for (int i = 0; i < 4; i += if (i == 1) { continue; } else { 1 }) "
        "{ auto tick = [by = i] \\ -> by; n += tick(); if (i == 1) { i += 2; "
        "} } return found + n; } }",
        // A return out of a value block inside a loop expression, with
        // closures created in the loop.
        "namespace Fuzz; class Program { "
        "public static int Step(_ int n) { return n > 0 ? 1 + Step(n - 1) "
        ": 0; } "
        "public static int Evaluate() { int a = Step(4); int t = 0; "
        "int r = while (true) { t += 1; auto seen = [at = t] \\ -> at; "
        "int q = if (seen() > a) { return seen() * 10; } else { seen() }; "
        "if (q == 3) { break q; } }; return r; } }",
        // Callables whose result type is inferred from returns that stand
        // in a value block and in a loop expression.
        "namespace Fuzz; class Program { "
        "public static int Step(_ int n) { return n > 0 ? 1 + Step(n - 1) "
        ": 0; } "
        "public static int Evaluate() { int a = Step(4); "
        "auto pick = \\(int v) -> { int q = if (v > 0) { return 1; } "
        "else { 2 }; return q; }; "
        "auto scan = [limit = a] \\(int v) -> { int q = while (true) { "
        "if (v > limit) { return 7; } break 2; }; return q + v; }; "
        "return pick(a) + scan(a); } }",
        // A callable every path of which returns from a value block, and
        // one whose returns are a different type from its creator's.
        "namespace Fuzz; class Program { "
        "public static int Step(_ int n) { return n > 0 ? 1 + Step(n - 1) "
        ": 0; } "
        "public static int Evaluate() { int a = Step(4); "
        "auto twice = \\(int v) -> { int q = if (v > 0) { return v * 2; } "
        "else { return 0 - v; }; return q; }; "
        "auto positive = \\(int w) -> { bool b = if (w > 0) { return true; "
        "} else { false }; return b; }; "
        "int q = if (positive(a)) { return twice(a); } else { 20 }; "
        "return q; } }",
        // A continue in a loop condition and a break in a loop update,
        // each with a closure alive at the transfer.
        "namespace Fuzz; class Program { "
        "public static int Step(_ int n) { return n > 0 ? 1 + Step(n - 1) "
        ": 0; } "
        "public static int Evaluate() { int a = Step(4); int c = 0; "
        "auto limit = [of = a] \\ -> of; int n = 0; "
        "while (if ((c += 1) < limit()) { continue; } else { n < 2 }) { "
        "auto tick = [by = n] \\ -> by + 1; n = tick(); } "
        "for (int i = 0; i < 9; i += if (i == limit()) { break; } else { 1 "
        "}) { auto add = [by = i] \\(int w) -> w + by; n = add(n); } "
        "return c * 100 + n; } }",
        // A callable created inside a callable: the inner one reads a
        // parameter of the outer one and a local of the method, which the
        // outer one must capture for it and nothing else.
        "namespace Fuzz; class Program { "
        "public static int Step(_ int n) { return n > 0 ? 1 + Step(n - 1) "
        ": 0; } "
        "public static int Evaluate() { int k = Step(4); "
        "auto outer = \\(int v) -> { auto inner = \\(int w) -> w + k + v; "
        "return inner(v) * 2; }; return outer(k); } }",
        // Three levels, with explicit and implicit captures mixed.
        "namespace Fuzz; class Program { "
        "public static int Step(_ int n) { return n > 0 ? 1 + Step(n - 1) "
        ": 0; } "
        "public static int Evaluate() { int k = Step(4); "
        "auto a = [k] \\(int v) -> { auto b = \\(int w) -> { "
        "auto c = [k, v, w] \\(int x) -> x + w * 10 + v * 100 + k * 1000; "
        "return c(1); }; return b(2); }; return a(3); } }",
        // An inner callable that outlives the call that created it.
        "namespace Fuzz; class Program { "
        "public static int Step(_ int n) { return n > 0 ? 1 + Step(n - 1) "
        ": 0; } "
        "public static int Evaluate() { int k = Step(4); "
        "auto make = \\(int v) -> { auto inner = \\(int w) -> w + v; "
        "return inner; }; auto f = make(k); auto g = make(k + 2); "
        "return f(2) * 100 + g(2); } }",
    } };

    // Methods whose return type is inferred, called from the bodies below.
    // A chain is declared against the order of its inference, and two
    // methods return each other.
    constexpr std::string_view kInferredHelpers
        = "    public static auto Twice(_ int value) { return value + "
          "value; }\n"
          "    public static auto Factorial(_ int value) { if (value <= 1) "
          "{ return 1; } return value * Factorial(value - 1); }\n"
          "    public static auto First(_ int v) { return Second(v) + 1; "
          "}\n"
          "    public static auto Second(_ int v) { return Third(v) + 10; "
          "}\n"
          "    public static auto Third(_ int v) { return v * 2; }\n"
          "    public static auto Even(_ int v) { if (v == 0) { return "
          "true; } return Odd(v - 1); }\n"
          "    public static auto Odd(_ int v) { if (v == 0) { return "
          "false; } return Even(v - 1); }\n"
          "    public static auto Pick(_ int v) { int q = if (v > 0) { "
          "return v * 3; } else { 5 }; return q + 1; }\n"
          "    public static auto Scan(_ int v) { int q = while (true) { "
          "if (v > 3) { return 7; } break 2; }; return q + v; }\n";

    // Closures that are created and called. Each expected value is worked
    // out by hand from the capture rules: a capture initializer is
    // evaluated once, where the closure is created; a closure created
    // inside another reads the names around both through the outer one;
    // and a closure keeps what it captured after the call that created it
    // has returned.
    constexpr auto kClosureCases = std::to_array<
        Progmasoft::Tala::Fuzzing::ExecutionCase>({
        { false,
          false,
          3,
          0,
          8,
          "auto outer = \\(int v) -> { auto inner = \\(int w) -> w + 1; "
          "return inner(v) * 2; }; return outer(left);" },
        { false,
          false,
          3,
          3,
          18,
          "int k = left; auto outer = \\(int v) -> { auto inner = "
          "\\(int w) -> w + k + v; return inner(v) * 2; }; "
          "return outer(right);" },
        { false,
          false,
          5,
          1,
          14,
          "int k = left; auto outer = \\(int v) -> { auto inner = "
          "\\(int w) -> w + k + v; return inner(v) * 2; }; "
          "return outer(right);" },
        { false,
          false,
          3,
          3,
          9,
          "int k = left; auto outer = [k] \\(int v) -> { auto inner = "
          "[k, v] \\(int w) -> w + k + v; return inner(v); }; "
          "return outer(right);" },
        { false,
          false,
          4,
          0,
          4321,
          "int k = left; auto a = \\(int v) -> { auto b = \\(int w) -> { "
          "auto c = \\(int x) -> x + w * 10 + v * 100 + k * 1000; "
          "return c(1); }; return b(2); }; return a(3);" },
        { false,
          false,
          5,
          7,
          709,
          "auto make = \\(int v) -> { auto inner = \\(int w) -> w + v; "
          "return inner; }; auto f = make(left); auto g = make(right); "
          "return f(2) * 100 + g(2);" },
        { false,
          false,
          1,
          0,
          111,
          "int k = left; auto held = [kept = k] \\ -> kept; k += 10; "
          "return held() * 100 + k;" },
        { false,
          false,
          3,
          0,
          12,
          "auto pick = \\(int v) -> { int q = if (v > 0) { return 1; } "
          "else { 2 }; return q; }; "
          "return pick(left) * 10 + pick(0 - left);" },
        { false,
          false,
          1,
          0,
          307,
          "auto scan = \\(int v) -> { int q = while (true) { "
          "if (v > 3) { return 7; } break 2; }; return q + v; }; "
          "return scan(left) * 100 + scan(left + 3);" },
        { false,
          false,
          3,
          0,
          6,
          "int n = 0; int t = 0; while (if (n >= left) { break; } else { "
          "true }) { auto step = [by = n] \\ -> by + 1; n = step(); "
          "t += n; } return t;" },
        { false,
          false,
          3,
          0,
          6,
          "int t = 0; for (int i = 0; i < 10; i += if (i == left) { "
          "break; } else { 1 }) { auto add = [by = i] \\(int w) -> w + "
          "by; t = add(t); } return t;" },
        // A closure passed to a method, made by one and returned by one.
        { false, false, 4, 0, 12, "return Apply(\\(int w) -> w * 3, left);" },
        { false,
          false,
          5,
          2,
          711,
          "auto add = Adder(left); auto ten = Adder(10); "
          "return add(right) * 100 + ten(1);" },
        { false,
          false,
          3,
          0,
          8,
          "auto f = \\(int w) -> w + 1; auto g = Pass(f); "
          "return g(left) + f(left);" },
        { false,
          false,
          5,
          1,
          6,
          "auto a = \\(int w) -> w + 1; auto b = \\(int w) -> w * 2; "
          "auto c = Choose(left > right, a, b); return c(left);" },
        { false,
          false,
          5,
          9,
          10,
          "auto a = \\(int w) -> w + 1; auto b = \\(int w) -> w * 2; "
          "auto c = Choose(left > right, a, b); return c(left);" },
        // A method named where a value is expected.
        { false,
          false,
          3,
          4,
          14,
          "auto f = Plain; return Apply(f, left) + Apply(Plain, right);" },
        // A closure variable assigned again, in a loop and from itself.
        { false,
          false,
          3,
          0,
          103,
          "auto f = Adder(0); for (int i = 1; i <= left; i += 1) { "
          "f = Adder(i); } return f(100);" },
        { false,
          false,
          0,
          0,
          100,
          "auto f = Adder(0); for (int i = 1; i <= left; i += 1) { "
          "f = Adder(i); } return f(100);" },
        { false,
          false,
          5,
          0,
          7,
          "auto f = Adder(1); f = Compose2(f); return f(left);" },
        // Closures that exist on one branch only.
        { false,
          false,
          4,
          1,
          5,
          "int r = 0; if (left > right) { auto f = Adder(left); "
          "r = f(1); } else { auto g = Adder(right); "
          "auto h = Compose2(g); r = h(1); } return r;" },
        { false,
          false,
          1,
          3,
          7,
          "int r = 0; if (left > right) { auto f = Adder(left); "
          "r = f(1); } else { auto g = Adder(right); "
          "auto h = Compose2(g); r = h(1); } return r;" },
        // A closure result that nothing receives.
        { false,
          false,
          5,
          0,
          7,
          "_ = Adder(left); auto f = Adder(2); _ = Adder(3); "
          "return f(left);" },
        // A closure kept alive only by the closure that captured it.
        { false,
          false,
          5,
          1,
          12,
          "auto inner = Adder(left); auto outer = \\(int w) -> "
          "inner(w) * 2; return outer(right);" },
        // A closure made in every pass of a loop that returns from
        // its middle.
        { false,
          false,
          4,
          0,
          103,
          "for (int i = 0; i < 5; i += 1) { auto f = Adder(i); "
          "if (f(left) > 6) { return f(100); } } return 0;" },
        { false,
          false,
          0,
          0,
          0,
          "for (int i = 0; i < 5; i += 1) { auto f = Adder(i); "
          "if (f(left) > 6) { return f(100); } } return 0;" },
    });

    // Methods that take, make and return closures. A parameter is borrowed
    // and a result is owned, so `Pass` and `Choose` must hand out a
    // reference of their own, and the closure of `Compose2` must keep the
    // closure it was given.
    constexpr std::string_view kClosureHelpers
        = "    public static int Apply(_ (int) -> int f, _ int v) { return "
          "f(v); }\n"
          "    public static (int) -> int Adder(_ int n) { return \\(int w) "
          "-> w + n; }\n"
          "    public static (int) -> int Pass(_ (int) -> int f) { return "
          "f; }\n"
          "    public static (int) -> int Choose(_ bool c, _ (int) -> int a, "
          "_ (int) -> int b) { if (c) { return a; } return b; }\n"
          "    public static (int) -> int Compose2(_ (int) -> int f) { "
          "return \\(int w) -> f(f(w)); }\n"
          "    public static int Plain(_ int value) { return value + value; "
          "}\n";

    // Classic enums. A value of an enum is its underlying integer in the
    // generated code, so these runs show that the numbering of members, the
    // comparison of values and the selection of a match arm by member
    // survive every native stage.
    constexpr std::string_view kEnumDeclarations
        = "enum Status { NONE, UNKNOWN = 0, READY }\n"
          "enum Level = byte { LOW = 1, MID, HIGH = 10, TOP }\n"
          // Values computed from earlier members: 1, 2, 4, 7, 8, 2, 250, 5.
          "enum Flag = ubyte { READ = 1, WRITE = READ << 1, EXECUTE = WRITE * "
          "2, ALL = READ | WRITE | EXECUTE, NEXT, HALF = EXECUTE / 2, REST = "
          "!(EXECUTE + 1), ROUNDED = 9 // 2 }\n";
    constexpr std::string_view kEnumHelpers
        = "    public static Status Pick(_ int v) { if (v > 0) { return "
          "Status.READY; } return Status.NONE; }\n"
          "    public static int Rank(_ Level l) { return match (l) { .LOW "
          "-> 1, .MID -> 2, .HIGH -> 10, .TOP -> 11 }; }\n"
          "    public static Level Raise(_ Level l) { return match (l) { "
          ".LOW -> Level.MID, .MID -> Level.HIGH, _ -> Level.TOP }; }\n"
          "    public static Flag Bit(_ int v) { return match (v) { 1 -> "
          ".READ, 2 -> .WRITE, 4 -> .EXECUTE, 7 -> .ALL, 8 -> .NEXT, 250 -> "
          ".REST, 5 -> .ROUNDED, _ -> .HALF }; }\n";
    constexpr auto kEnumCases = std::to_array<
        Progmasoft::Tala::Fuzzing::ExecutionCase>({
        // A member has the value its expression computes from the
        // members before it; a match over them is complete when every
        // value is named.
        { false,
          false,
          1,
          0,
          1,
          "return match (Bit(left)) { .READ -> 1, .HALF -> 2, .EXECUTE -> 3, "
          ".ALL -> 4, .NEXT -> 5, .REST -> 6, .ROUNDED -> 7 };" },
        { false,
          false,
          2,
          0,
          2,
          "return match (Bit(left)) { .READ -> 1, .HALF -> 2, .EXECUTE -> 3, "
          ".ALL -> 4, .NEXT -> 5, .REST -> 6, .ROUNDED -> 7 };" },
        { false,
          false,
          4,
          0,
          3,
          "return match (Bit(left)) { .READ -> 1, .HALF -> 2, .EXECUTE -> 3, "
          ".ALL -> 4, .NEXT -> 5, .REST -> 6, .ROUNDED -> 7 };" },
        { false,
          false,
          7,
          0,
          4,
          "return match (Bit(left)) { .READ -> 1, .HALF -> 2, .EXECUTE -> 3, "
          ".ALL -> 4, .NEXT -> 5, .REST -> 6, .ROUNDED -> 7 };" },
        { false,
          false,
          8,
          0,
          5,
          "return match (Bit(left)) { .READ -> 1, .HALF -> 2, .EXECUTE -> 3, "
          ".ALL -> 4, .NEXT -> 5, .REST -> 6, .ROUNDED -> 7 };" },
        { false,
          false,
          250,
          0,
          6,
          "return match (Bit(left)) { .READ -> 1, .HALF -> 2, .EXECUTE -> 3, "
          ".ALL -> 4, .NEXT -> 5, .REST -> 6, .ROUNDED -> 7 };" },
        { false,
          false,
          5,
          0,
          7,
          "return match (Bit(left)) { .READ -> 1, .HALF -> 2, .EXECUTE -> 3, "
          ".ALL -> 4, .NEXT -> 5, .REST -> 6, .ROUNDED -> 7 };" },
        { false, false, 0, 0, 1, "return Flag.HALF == Flag.WRITE ? 1 : 0;" },
        { false, false, 0, 0, 0, "return Flag.NEXT == Flag.ALL ? 1 : 0;" },
        { false,
          false,
          3,
          0,
          1,
          "Status s = Pick(left); return s == Status.READY ? 1 : 2;" },
        { false,
          false,
          0,
          0,
          2,
          "Status s = Pick(left); return s == Status.READY ? 1 : 2;" },
        { false,
          false,
          0,
          0,
          2,
          "Status s = Pick(left); return s \\= Status.NONE ? 1 : 2;" },
        { false,
          false,
          0,
          0,
          1,
          "return Status.NONE == Status.UNKNOWN ? 1 : 2;" },
        { false,
          false,
          0,
          0,
          12021,
          "return Rank(Level.LOW) + Rank(Level.MID) * 10 + "
          "Rank(Level.HIGH) * 100 + Rank(Level.TOP) * 1000;" },
        { false,
          false,
          3,
          0,
          20,
          "return match (Pick(left)) { .NONE -> 10, .READY -> 20 };" },
        { false,
          false,
          0,
          0,
          10,
          "return match (Pick(left)) { .NONE -> 10, .READY -> 20 };" },
        { false,
          false,
          0,
          0,
          10,
          "return match (Pick(left)) { .UNKNOWN -> 10, .READY -> 20 };" },
        { false,
          false,
          1,
          1,
          1,
          "return match (Pick(left)) { .READY if (right > 0) -> 1, "
          ".READY -> 2, .NONE -> 3 };" },
        { false,
          false,
          1,
          0,
          2,
          "return match (Pick(left)) { .READY if (right > 0) -> 1, "
          ".READY -> 2, .NONE -> 3 };" },
        { false,
          false,
          0,
          5,
          3,
          "return match (Pick(left)) { .READY if (right > 0) -> 1, "
          ".READY -> 2, .NONE -> 3 };" },
        { false,
          false,
          0,
          0,
          1011,
          "return Rank(Raise(Raise(Level.LOW))) * 100 + "
          "Rank(Raise(Level.HIGH));" },
        { false,
          false,
          1,
          0,
          1,
          "Status s = match (left) { 1 -> Status.READY, _ -> Status.NONE "
          "}; return s == Status.READY ? 1 : 0;" },
        { false,
          false,
          0,
          1,
          1,
          "return match (Pick(left)), (right > 0) { (.NONE), (true) -> 1, "
          "(.NONE), (false) -> 2, (.READY), (true) -> 3, (.READY), (false) "
          "-> 4 };" },
        { false,
          false,
          1,
          0,
          4,
          "return match (Pick(left)), (right > 0) { (.NONE), (true) -> 1, "
          "(.NONE), (false) -> 2, (.READY), (true) -> 3, (.READY), (false) "
          "-> 4 };" },
        { false,
          false,
          0,
          0,
          3,
          "Level l = Level.LOW; int n = 0; while (l \\= Level.TOP) { "
          "l = Raise(l); n += 1; } return n;" },
        { false,
          false,
          2,
          0,
          56,
          "auto f = \\(Status s) -> s == Status.READY ? 5 : 6; "
          "return f(Pick(left)) * 10 + f(Status.NONE);" },
        // The target-typed spelling, and enums as the value of a
        // conditional and of a loop expression.
        { false,
          false,
          3,
          0,
          1,
          "Status s = Pick(left); return s == .READY ? 1 : 2;" },
        { false, false, 0, 0, 11, "return Rank(.HIGH) + Rank(.LOW);" },
        { false,
          false,
          1,
          0,
          1,
          "Status s = left > 0 ? .READY : .NONE; "
          "return s == .READY ? 1 : 0;" },
        { false,
          false,
          1,
          0,
          11,
          "Level l = while (true) { if (left > 0) { break Level.TOP; } "
          "break Level.MID; }; return Rank(l);" },
        { false,
          false,
          0,
          0,
          2,
          "Level l = while (true) { if (left > 0) { break Level.TOP; } "
          "break Level.MID; }; return Rank(l);" },
    });

    // Evaluation by need. A value that is never needed is never computed, so
    // a division by zero and a call that never returns do nothing when
    // nothing reads their value; run through LLVM, the first would end the
    // process and the second would never end. A store happens where it is
    // written, and a value means what its variables held where it was
    // bound.
    // Arguments passed by need. A method computes an argument when it first
    // needs it, at most once, and never when it does not need it; a value
    // the caller needs as well is computed once for both. Such a value is
    // an object of the runtime, so each case is a program of its own and
    // must leave no allocation behind.
    constexpr std::string_view kByNeedHelpers
        = "    public static int Never(_ int v) { return Never(v + 1); "
          "}\n"
          "    public static int Half(_ int v) { return v / 2; }\n"
          "    public static int Step(_ int n) { return n > 0 ? 1 + "
          "Step(n - 1) : 0; }\n"
          "    public static int Pick(_ int flag, _ int value) { if "
          "(flag > 0) { return value; } return 7; }\n"
          "    public static int Pass(_ int flag, _ int value) { return"
          " Pick(flag, value); }\n"
          "    public static int Both(_ int flag, _ int first, _ int "
          "second) { if (flag > 0) { return first; } return second; }\n"
          "    public static int Kept(_ int flag, _ int value) { auto "
          "read = \\(int more) -> value + more; if (flag > 0) { return "
          "read(1); } return 3; }\n"
          "    public static int Often(_ int flag, _ int value) { int "
          "total = 0; for (int i = 0; i < 50; i += 1) { if (flag > 0) {"
          " total += value; } } return total; }\n"
          "    public static int Down(_ int n, _ int spare) { if (n <= "
          "0) { return 0; } return 1 + Down(n - 1, spare / 0); }\n";
    constexpr auto kByNeedCases = std::to_array<
        Progmasoft::Tala::Fuzzing::ExecutionCase>({
        // An argument that the method never needs is never computed.
        { false, false, 6, 0, 7, "return Pick(right, left / right);" },
        { false, false, 6, 3, 2, "return Pick(right, left / right);" },
        { false, false, 1, 0, 7, "return Pick(right, Never(left));" },
        { false,
          false,
          8,
          0,
          11,
          "return Pick(0, Never(left)) + Pick(1, Half(left));" },
        { false, false, 5, 0, 6, "return Both(right, Never(left), left + 1);" },
        { false,
          false,
          6,
          3,
          2,
          "return Both(right, left / right, Never(left));" },
        // A value handed through one method to another, and through a method
        // that calls itself.
        { false, false, 6, 0, 7, "return Pass(right, left / right);" },
        { false, false, 6, 3, 2, "return Pass(right, left / right);" },
        { false,
          false,
          6,
          2,
          4,
          "return Pick(right, Pick(right, left / right) + 1);" },
        { false, false, 5, 0, 5, "return Down(left, right);" },
        // A local by need that is handed on, and that the caller needs as
        // well.
        { false,
          false,
          1,
          0,
          7,
          "int x = Never(left); int y = Pick(right, x); return y;" },
        { false,
          false,
          6,
          0,
          14,
          "int x = left / right; return Pick(right, x) + Pick(right, x "
          "+ 1);" },
        { false,
          false,
          6,
          3,
          5,
          "int x = left / right; return Pick(right, x) + Pick(right, x "
          "+ 1);" },
        { false,
          false,
          30,
          1,
          60,
          "int x = Step(left); int y = Pick(right, x); return right > 0"
          " ? x + y : y;" },
        { false,
          false,
          30,
          0,
          7,
          "int x = Step(left); int y = Pick(right, x); return right > 0"
          " ? x + y : y;" },
        { false,
          false,
          6,
          3,
          6,
          "int x = left / right; int y = x + 1; return Pass(right, y * "
          "2);" },
        { false,
          false,
          6,
          0,
          7,
          "int x = left / right; int y = x + 1; return Pass(right, y * "
          "2);" },
        // An argument means what its variables held at the call, and a store
        // in it happens there.
        { false,
          false,
          8,
          1,
          12100,
          "int a = left; int r = Pick(right, Half(a) + a); a = 100; "
          "return r * 1000 + a;" },
        { false,
          false,
          1,
          0,
          17,
          "int n = 0; int r = Pick(0, (n += 1) + left); return n * 10 +"
          " r;" },
        // An argument the method reads often, one a closure of the method
        // captures, and one for each pass of a loop.
        { false, false, 8, 1, 200, "return Often(right, Half(left));" },
        { false, false, 8, 0, 0, "return Often(right, Half(left));" },
        { false, false, 6, 3, 3, "return Kept(1, left / right);" },
        { false,
          false,
          12,
          0,
          29,
          "int t = 0; for (int i = 0; i <= 3; i += 1) { t += Pick(i, "
          "left / i); } return t;" },
    });

    constexpr std::string_view kLazyHelpers
        = "    public static int Never(_ int v) { return Never(v + 1); }\n"
          "    public static int Half(_ int v) { return v / 2; }\n";
    constexpr auto kLazyCases = std::to_array<
        Progmasoft::Tala::Fuzzing::ExecutionCase>({
        { false, false, 1, 0, 5, "int x = left / right; return 5;" },
        // A value that needs another value twice computes it once, also
        // through a chain of such values.
        { false,
          false,
          6,
          0,
          7,
          "int z0 = left / right; int z1 = z0 / 1 - z0 / 2; int z2 = z1 / 1 - "
          "z1 / 2; int z3 = z2 / 1 - z2 / 2; int z4 = z3 / 1 - z3 / 2; int z5 "
          "= z4 / 1 - z4 / 2; int z6 = z5 / 1 - z5 / 2; int z7 = z6 / 1 - z6 / "
          "2; int z8 = z7 / 1 - z7 / 2; int z9 = z8 / 1 - z8 / 2; int z10 = z9 "
          "/ 1 - z9 / 2; int z11 = z10 / 1 - z10 / 2; int z12 = z11 / 1 - z11 "
          "/ 2; int z13 = z12 / 1 - z12 / 2; int z14 = z13 / 1 - z13 / 2; int "
          "z15 = z14 / 1 - z14 / 2; int z16 = z15 / 1 - z15 / 2; int z17 = z16 "
          "/ 1 - z16 / 2; int z18 = z17 / 1 - z17 / 2; int z19 = z18 / 1 - z18 "
          "/ 2; int z20 = z19 / 1 - z19 / 2; int z21 = z20 / 1 - z20 / 2; int "
          "z22 = z21 / 1 - z21 / 2; int z23 = z22 / 1 - z22 / 2; int z24 = z23 "
          "/ 1 - z23 / 2; if (right > 0) { return z24; } return 7;" },
        { false,
          false,
          6,
          3,
          1,
          "int z0 = left / right; int z1 = z0 / 1 - z0 / 2; int z2 = z1 / 1 - "
          "z1 / 2; int z3 = z2 / 1 - z2 / 2; int z4 = z3 / 1 - z3 / 2; int z5 "
          "= z4 / 1 - z4 / 2; int z6 = z5 / 1 - z5 / 2; int z7 = z6 / 1 - z6 / "
          "2; int z8 = z7 / 1 - z7 / 2; int z9 = z8 / 1 - z8 / 2; int z10 = z9 "
          "/ 1 - z9 / 2; int z11 = z10 / 1 - z10 / 2; int z12 = z11 / 1 - z11 "
          "/ 2; int z13 = z12 / 1 - z12 / 2; int z14 = z13 / 1 - z13 / 2; int "
          "z15 = z14 / 1 - z14 / 2; int z16 = z15 / 1 - z15 / 2; int z17 = z16 "
          "/ 1 - z16 / 2; int z18 = z17 / 1 - z17 / 2; int z19 = z18 / 1 - z18 "
          "/ 2; int z20 = z19 / 1 - z19 / 2; int z21 = z20 / 1 - z20 / 2; int "
          "z22 = z21 / 1 - z21 / 2; int z23 = z22 / 1 - z22 / 2; int z24 = z23 "
          "/ 1 - z23 / 2; if (right > 0) { return z24; } return 7;" },
        { false,
          false,
          6,
          0,
          9,
          "int x = left / right; int y = right > 0 ? x / 1 + x / 2 : 0; return "
          "right > 1 ? y : 9;" },
        { false,
          false,
          6,
          1,
          9,
          "int x = left / right; int y = right > 0 ? x / 1 + x / 2 : 0; return "
          "right > 1 ? y : 9;" },
        { false,
          false,
          6,
          3,
          3,
          "int x = left / right; int y = right > 0 ? x / 1 + x / 2 : 0; return "
          "right > 1 ? y : 9;" },
        { false, false, 1, 0, 5, "int x = Never(left); return 5;" },
        { false,
          false,
          6,
          0,
          7,
          "int x = left / right; if (right > 0) { return x; } return 7;" },
        { false,
          false,
          6,
          3,
          2,
          "int x = left / right; if (right > 0) { return x; } return 7;" },
        { false,
          false,
          6,
          0,
          1,
          "int x = left / right; return match (right) { 0 -> 1, _ -> x };" },
        { false,
          false,
          6,
          2,
          3,
          "int x = left / right; return match (right) { 0 -> 1, _ -> x };" },
        { false,
          false,
          6,
          0,
          2,
          "int x = left / right; return right > 0 && x > 1 ? 1 : 2;" },
        { false,
          false,
          6,
          3,
          1,
          "int x = left / right; return right > 0 && x > 1 ? 1 : 2;" },
        { false,
          false,
          6,
          0,
          9,
          "int x = left / right; int y = x + 1; return right > 0 ? y : 9;" },
        { false,
          false,
          6,
          3,
          3,
          "int x = left / right; int y = x + 1; return right > 0 ? y : 9;" },
        { false,
          false,
          0,
          1,
          1,
          "int x = Never(left); int y = x + 1; int z = y * 2; "
          "return right > 0 ? 1 : 2;" },
        { false,
          false,
          12,
          0,
          10,
          "int t = 0; for (int i = 0; i <= 3; i += 1) { int x = left / i; "
          "if (i > 1) { t += x; } } return t;" },
        { false,
          false,
          6,
          0,
          0,
          "int limit = left / right; int n = 0; "
          "while (right > 0 && n < limit) { n += 1; } return n;" },
        { false,
          false,
          6,
          2,
          3,
          "int limit = left / right; int n = 0; "
          "while (right > 0 && n < limit) { n += 1; } return n;" },
        { false,
          false,
          8,
          0,
          12100,
          "int a = left; int x = Half(a) + a; a = 100; "
          "return x * 1000 + a;" },
        { false,
          false,
          8,
          1,
          4,
          "int a = left; int x = Half(a); a = a + 100; "
          "if (right > 0) { return x; } return a;" },
        { false,
          false,
          8,
          0,
          108,
          "int a = left; int x = Half(a); a = a + 100; "
          "if (right > 0) { return x; } return a;" },
        { false,
          false,
          1,
          0,
          10,
          "int n = 0; int x = (n += 1) + left; return n * 10;" },
        // The body of a callable evaluates by need as well.
        { false,
          false,
          6,
          0,
          7,
          "auto f = \\(int v, int d) -> { int q = v / d; if (d > 0) { "
          "return q; } return 7; }; return f(left, right);" },
        { false,
          false,
          6,
          3,
          2,
          "auto f = \\(int v, int d) -> { int q = v / d; if (d > 0) { "
          "return q; } return 7; }; return f(left, right);" },
        { false,
          false,
          1,
          0,
          5,
          "auto f = \\(int v) -> { int q = Never(v); return 5; }; "
          "return f(left);" },
        { false,
          false,
          6,
          0,
          9,
          "auto f = \\(int v, int d) -> { auto g = \\(int w) -> { "
          "int q = w / d; return d > 0 ? q : 9; }; return g(v); }; "
          "return f(left, right);" },
    });

    // Written here by hand, apart from the generated tables and from the
    // frontend tests: the expected values are worked out from the methods
    // above, so these runs do not share an expectation with any other
    // table.
    constexpr auto kInferredCases = std::to_array<
        Progmasoft::Tala::Fuzzing::ExecutionCase>({
        { false, false, 3, 4, 30, "return Twice(left) + Factorial(right);" },
        { false, false, 0, 1, 1, "return Twice(left) + Factorial(right);" },
        { false, false, 4, 0, 19, "return First(left);" },
        { false,
          false,
          4,
          0,
          12,
          "return (Even(left) ? 10 : 20) + (Odd(left) ? 1 : 2);" },
        { false,
          false,
          3,
          0,
          21,
          "return (Even(left) ? 10 : 20) + (Odd(left) ? 1 : 2);" },
        { false, false, 2, 0, 66, "return Pick(left) * 10 + Pick(0 - left);" },
        { false,
          false,
          1,
          0,
          307,
          "return Scan(left) * 100 + Scan(left + 3);" },
        { false,
          false,
          3,
          0,
          6,
          "int x = Twice(left); bool b = Even(x); return b ? x : 0 - x;" },
    });

    int
    Smoke()
    {
        // Hand-written results for calls of methods whose return type is
        // inferred.
        Progmasoft::Tala::Fuzzing::ExerciseExecutionCases(
            "Inferred return execution",
            kInferredCases,
            kInferredHelpers);
        // Hand-written results for evaluation by need.
        Progmasoft::Tala::Fuzzing::ExerciseExecutionCases("Lazy execution",
                                                          kLazyCases,
                                                          kLazyHelpers);
        // Hand-written results for classic enums.
        Progmasoft::Tala::Fuzzing::ExerciseExecutionCases("Enum execution",
                                                          kEnumCases,
                                                          kEnumHelpers,
                                                          kEnumDeclarations);
        // The JIT finds the runtime of the closure cases in this process.
        // The call also keeps the runtime in the program where the linker
        // would otherwise leave an unreferenced library out.
        if (tala_aarc_abi_version() != TALA_AARC_ABI_VERSION)
        {
            llvm::errs() << "the linked AARC runtime has another ABI version\n";
            return 1;
        }
        // Hand-written results for closures: created, called, nested and
        // returned, through LLVM and the runtime that owns them.
        // Each case is a program of its own, and the runtime must hold no
        // more allocations after it than before: a closure that is not
        // released, or a capture its destructor does not release, is a
        // failure here on every platform, with the program that leaked.
        for (const auto &closureCase : kClosureCases)
        {
            const auto before
                = Progmasoft::Tala::Runtime::Aarc::LiveAllocations();
            Progmasoft::Tala::Fuzzing::ExerciseExecutionCases(
                "Closure execution",
                std::span(&closureCase, 1U),
                kClosureHelpers);
            const auto after
                = Progmasoft::Tala::Runtime::Aarc::LiveAllocations();
            if (after != before)
            {
                llvm::errs()
                    << "closure case left " << (after - before)
                    << " AARC allocation(s) behind: " << closureCase.body
                    << '\n';
                return 1;
            }
        }
        for (const auto &byNeedCase : kByNeedCases)
        {
            const auto before
                = Progmasoft::Tala::Runtime::Aarc::LiveAllocations();
            Progmasoft::Tala::Fuzzing::ExerciseExecutionCases(
                "By-need execution",
                std::span(&byNeedCase, 1U),
                kByNeedHelpers);
            const auto after
                = Progmasoft::Tala::Runtime::Aarc::LiveAllocations();
            if (after != before)
            {
                llvm::errs()
                    << "by-need case left " << (after - before)
                    << " AARC allocation(s) behind: " << byNeedCase.body
                    << '\n';
                return 1;
            }
        }
        for (const auto text : kOwnershipCases)
        {
            llvm::errs() << "Ownership verification: " << text << '\n';
            // The bytes of the text are the input, as a fuzz target gets it.
            // NOLINTNEXTLINE(cppcoreguidelines-pro-type-reinterpret-cast)
            const auto *const bytes
                = reinterpret_cast<const std::uint8_t *>(text.data());
            Progmasoft::Tala::Fuzzing::ExerciseAcceptedSource(
                { bytes, text.size() });
        }
        return 0;
    }
} // namespace

int
main()
{
    // The compiler runs on its own stack, as in `talac`.
    return Progmasoft::Tala::Support::RunOnCompilerStack([] {
        return Smoke();
    });
}
