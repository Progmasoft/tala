// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iterator>
#include <llvm/Support/raw_ostream.h>
#include <string>
#include <string_view>

#include "Progmasoft/Tala/Runtime/AARC.hpp"
#include "Progmasoft/Tala/Runtime/Text.hpp"
#include "Progmasoft/Tala/Support/CompilerStack.hpp"
#include "SourceFuzz.hpp"

// Programs that write, run through the whole compiler.
//
// Each program is compiled from source through CorePrep, Xpp, Xmm, LLVM and
// the ORC JIT, unoptimized and optimized, and what it wrote to standard
// output and to standard error is compared with text written by hand. The
// runtime the generated code calls is the library this program links; its
// output goes to a sink instead of the streams of the process.
//
// The frontend tests run the same kind of program in a reference evaluator
// whose text functions are written a second time, in Haskell. This program
// is the other half: the generated code, the calling convention of each
// runtime function, and the runtime library itself.
//
// A string is an object of the runtime, so every program runs alone and
// must leave no allocation behind.

namespace
{
    namespace Aarc = Progmasoft::Tala::Runtime::Aarc;
    namespace Console = Progmasoft::Tala::Runtime::Console;

    struct Captured final
    {
        std::string output;
        std::string error;
    };

    void
    Receive(std::int64_t stream,
            const char *bytes,
            std::size_t count,
            void *context) noexcept
    {
        auto *captured = static_cast<Captured *>(context);
        (stream == TALA_CONSOLE_ERROR ? captured->error : captured->output)
            .append(bytes, count);
    }

    /// One program: the body of `Evaluate`, and what it writes. In the
    /// expected text a line feed stands for the line terminator of the
    /// platform; no program here writes a line feed of its own.
    struct ConsoleCase final
    {
        std::string_view body;
        std::string_view output;
        std::string_view error;
    };

    constexpr std::string_view kHelpers
        = "    public static int Zero() { return 0; }\n"
          "    public static int Half(_ int v) { return v / 2; }\n"
          "    public static int Pick(_ int flag, _ int value) {"
          " if (flag > 0) { return value; } return 7; }\n"
          "    public static int Log(_ int v) {"
          " Console.Println(v); return v; }\n"
          "    public static String Name() { return \"Tala\"; }\n"
          "    public static String Twice(_ String s) { return s + s; }\n"
          "    public static void Greet(_ String who) {"
          " Console.Println(\"Hello, \" + who + \"!\"); }\n"
          "    public static String Fizz(_ int n) {\n"
          "        if (n % 15 == 0) { return \"FizzBuzz\"; }\n"
          "        if (n % 3 == 0) { return \"Fizz\"; }\n"
          "        if (n % 5 == 0) { return \"Buzz\"; }\n"
          "        return \"\" + n;\n"
          "    }\n";

    constexpr ConsoleCase kCases[] = {
        // Plain output.
        { "Console.Print(\"a\"); Console.Print(\"b\");", "ab", "" },
        { "Console.Println(\"Hello\");", "Hello\n", "" },
        { "Console.Println(\"\");", "\n", "" },
        { "System.Console.Println(\"qualified\");", "qualified\n", "" },
        { "Console.Println(\"%d\");", "%d\n", "" },
        { "Console.Println(42);", "42\n", "" },
        { "Console.Println(0 - 7);", "-7\n", "" },
        { "Console.Println(true);", "true\n", "" },
        { "Console.Println('x');", "x\n", "" },
        { "int n = 9223372036854775807; Console.Println(n);",
          "9223372036854775807\n",
          "" },
        { "uint u = 18446744073709551615; Console.Println(u);",
          "18446744073709551615\n",
          "" },
        { "byte small = 100; Console.Println(small);", "100\n", "" },
        { "ushort medium = 65535; Console.Println(medium);", "65535\n", "" },
        // Characters outside ASCII leave as UTF-8.
        { "Console.Println(\"\xc3\xa9\xe2\x82\xac\");",
          "\xc3\xa9\xe2\x82\xac\n",
          "" },
        // Standard error.
        { "Console.Error(\"e\"); Console.Errorln(\"f\");", "", "ef\n" },
        { "Console.Print(\"a\"); Console.Errorln(\"b\"); Console.Print(\"c\");",
          "ac",
          "b\n" },
        { "Console.Errorfn(\"Code: %d\", 7);", "", "Code: 7\n" },
        // Strings as values.
        { "String s = \"kept\"; Console.Println(s);", "kept\n", "" },
        { "Console.Println(Name());", "Tala\n", "" },
        { "Console.Println(Twice(\"ab\"));", "abab\n", "" },
        // + joins.
        { "String language = \"Tala\";"
          " Console.Println(\"Hello from \" + language + \"!\");",
          "Hello from Tala!\n",
          "" },
        { "Console.Println(\"n=\" + 5);", "n=5\n", "" },
        { "Console.Println(5 + \"n\");", "5n\n", "" },
        { "Console.Println(\"b=\" + true);", "b=true\n", "" },
        { "Console.Println(\"c=\" + 'z');", "c=z\n", "" },
        { "Console.Println(\"a\" + 1 + 2);", "a12\n", "" },
        { "uint u = 7; Console.Println(\"u=\" + u);", "u=7\n", "" },
        { "String t = \"x\"; t += \"y\"; t += 3; Console.Println(t);",
          "xy3\n",
          "" },
        { "String t = \"\";"
          " for (int i = 0; i < 4; i += 1) { t += i; } Console.Println(t);",
          "0123\n",
          "" },
        // Strings are compared by what they hold.
        { "Console.Println(\"a\" == \"a\");", "true\n", "" },
        { "Console.Println(\"a\" \\= \"a\");", "false\n", "" },
        { "String a = \"ab\"; String b = \"a\" + \"b\";"
          " Console.Println(a == b);",
          "true\n",
          "" },
        { "String a = \"ab\"; String b = \"a\" + \"c\";"
          " Console.Println(a == b);",
          "false\n",
          "" },
        { "if (Name() == \"Tala\") { Console.Println(\"same\"); }"
          " else { Console.Println(\"other\"); }",
          "same\n",
          "" },
        // Formats.
        { "Console.Printf(\"plain\");", "plain", "" },
        { "Console.Printfn(\"%d\", 42);", "42\n", "" },
        { "Console.Printfn(\"gcd(%d, %d) = %d\", 1071, 462, 21);",
          "gcd(1071, 462) = 21\n",
          "" },
        { "Console.Printf(\"%5d|\", 42);", "   42|", "" },
        { "Console.Printf(\"%-5d|\", 42);", "42   |", "" },
        { "Console.Printf(\"%05d\", 0 - 42);", "-0042", "" },
        { "Console.Printf(\"%+d\", 42);", "+42", "" },
        { "Console.Printf(\"%'d\", 0 - 1234567);", "-1'234'567", "" },
        { "byte small = 0 - 100; Console.Printf(\"%d\", small);", "-100", "" },
        { "Console.Printf(\"%x\", 0 - 255);", "-ff", "" },
        { "Console.Printf(\"%#08x\", 255);", "0x0000ff", "" },
        { "uint u = 4294967295; Console.Printf(\"%x\", u);", "ffffffff", "" },
        { "ubyte tiny = 255; Console.Printf(\"%u\", tiny);", "255", "" },
        { "uint u = 1234567; Console.Printf(\"%'u\", u);", "1'234'567", "" },
        { "Console.Printf(\"%10s|\", \"abc\");", "       abc|", "" },
        { "Console.Printf(\"%-10s|\", \"abc\");", "abc       |", "" },
        { "Console.Printf(\"%5.1s|\", \"abc\");", "    a|", "" },
        { "Console.Printf(\"%s: %d\", \"total\", 7);", "total: 7", "" },
        { "Console.Printf(\"%3c|\", 'q');", "  q|", "" },
        { "Console.Printf(\"%6b|\", false);", " false|", "" },
        { "Console.Printf(\"%b\", 1 > 2);", "false", "" },
        { "Console.Printf(\"%d%%\", 50);", "50%", "" },
        { "Console.Printf(\"A%nB\");", "A\nB", "" },
        { "Console.Printf(\"%f\", 12.5);", "12.500000", "" },
        { "Console.Printf(\"%.0f\", 2.5);", "2", "" },
        { "Console.Printf(\"%.0f\", 3.5);", "4", "" },
        { "Console.Printf(\"%010.3f\", 3.14159);", "000003.142", "" },
        { "Console.Printf(\"%'.2f\", 1234567.5);", "1'234'567.50", "" },
        { "Console.Printf(\"%.20f\", 0.1);", "0.10000000000000000555", "" },
        { "float price = 19.99; Console.Printfn(\"Price: %.2f\", price);",
          "Price: 19.99\n",
          "" },
        { "lfloat single = 0.5; Console.Printf(\"%.3f\", single);",
          "0.500",
          "" },
        { "Console.Printf(\"%*d|\", 5, 42);", "   42|", "" },
        { "Console.Printf(\"%*.*f|\", 8, 2, 3.14159);", "    3.14|", "" },
        { "String t = Console.Format(\"Name: %s, Age: %d\", \"Ada\", 36);"
          " Console.Println(t);",
          "Name: Ada, Age: 36\n",
          "" },
        { "Console.Print(Console.Format(\"%05d\", 42)"
          " + Console.Format(\"%x\", 255));",
          "00042ff",
          "" },
        // Strings that callables take, capture, make and return.
        { "auto greet = \\(String who) -> \"Hi \" + who;"
          " Console.Println(greet(\"Ada\"));",
          "Hi Ada\n",
          "" },
        { "String prefix = Name() + \": \";"
          " auto label = \\(int n) -> prefix + n;"
          " Console.Println(label(1)); Console.Println(label(2));",
          "Tala: 1\nTala: 2\n",
          "" },
        { "auto twice = \\(int v) -> { Console.Printf(\"%d,\", v);"
          " return v * 2; }; Console.Println(twice(twice(1)));",
          "1,2,4\n",
          "" },
        { "auto make = \\(int n) -> Console.Format(\"<%03d>\", n);"
          " String all = \"\"; for (int i = 0; i < 3; i += 1)"
          " { all += make(i); } Console.Println(all);",
          "<000><001><002>\n",
          "" },
        // A callable that is made and never called leaves nothing behind.
        { "String kept = Twice(\"ab\");"
          " auto never = \\(int n) -> kept + n; Console.Println(\"x\");",
          "x\n",
          "" },
        // A method is a callable value: it writes where its call stands.
        { "auto f = Log; int x = f(1); Console.Println(9);", "1\n9\n", "" },
        // Appending makes a new string; another name keeps the old one.
        { "String s = \"a\"; String t = s; s += \"b\";"
          " Console.Println(s + t);",
          "aba\n",
          "" },
        { "String s = \"\"; for (int i = 0; i < 5; i += 1)"
          " { String old = s; s += i; if (old == s) { s += \"!\"; } }"
          " Console.Println(s);",
          "01234\n",
          "" },
        // String operations in arguments that are and are not needed.
        { "Console.Println(Pick(1, Half(8)) + Name());", "4Tala\n", "" },
        { "String made = Twice(Name() + \"!\");"
          " Console.Println(Pick(0, 8 / Zero()));",
          "7\n",
          "" },
        { "Console.Println(Console.Format(\"[%s]\","
          " Console.Format(\"%5s\", Console.Format(\"%d\", 42))));",
          "[   42]\n",
          "" },
        { "Console.Println(Twice(Twice(\"ab\")) == \"abababab\");",
          "true\n",
          "" },
        // A conditional selects one of two strings; the other is never
        // made, and the one that is replaced is released.
        { "String s = Zero() > 0 ? \"a\" : \"b\"; Console.Println(s);",
          "b\n",
          "" },
        { "Console.Println(Zero() == 0 ? Name() : Twice(\"x\"));",
          "Tala\n",
          "" },
        { "String a = \"x\"; String b = \"y\";"
          " String c = Zero() > 0 ? a : b; Console.Println(c + a + b);",
          "yxy\n",
          "" },
        { "Console.Println(Zero() > 0 ? \"a\""
          " : Zero() == 0 ? \"b\" : \"c\");",
          "b\n",
          "" },
        { "String s = Zero() > 0 ? \"\" + Log(1) : \"\" + Log(2);"
          " Console.Println(s);",
          "2\n2\n",
          "" },
        { "String s = \"\"; for (int i = 0; i < 4; i += 1)"
          " { s += i % 2 == 0 ? \"e\" : \"o\"; } Console.Println(s);",
          "eoeo\n",
          "" },
        { "Greet(Zero() == 0 ? Name() : \"nobody\");", "Hello, Tala!\n", "" },
        { "String s = \"keep\"; s = Zero() > 0 ? \"lost\" : s;"
          " Console.Println(s);",
          "keep\n",
          "" },
        // A selected string nothing reads is released all the same.
        { "String s = Zero() == 0 ? Twice(\"ab\") : Name();"
          " Console.Println(\"x\");",
          "x\n",
          "" },
        // A match, an if used as a value and a loop yield strings; what is
        // not selected is never made, and what is replaced is released.
        { "String s = match (Zero()) { 0 -> \"zero\", 1 -> \"one\","
          " _ -> \"many\" }; Console.Println(s);",
          "zero\n",
          "" },
        { "String s = match (Half(8)) { 0 -> \"zero\","
          " int n if n > 3 -> \"big \" + n, _ -> \"small\" };"
          " Console.Println(s);",
          "big 4\n",
          "" },
        { "String s = if (Zero() > 0) { \"pos\" } else { Name() + \"!\" };"
          " Console.Println(s);",
          "Tala!\n",
          "" },
        { "int i = 0; String s = while (true) { i += 1;"
          " if (i > 2) { break \"done\" + i; } }; Console.Println(s);",
          "done3\n",
          "" },
        { "String s = \"k\"; s = match (Zero()) { 1 -> \"lost\", _ -> s };"
          " Console.Println(s);",
          "k\n",
          "" },
        { "String s = \"\"; for (int i = 0; i < 4; i += 1) { s += match"
          " (i % 3) { 0 -> \"a\", 1 -> \"b\", _ -> \"c\" }; }"
          " Console.Println(s);",
          "abca\n",
          "" },
        { "String s = match (Zero()) { 0 -> match (Half(2)) {"
          " 1 -> \"inner\", _ -> \"other\" }, _ -> \"outer\" };"
          " Console.Println(s);",
          "inner\n",
          "" },
        // A selected string nothing reads is released all the same.
        { "String s = match (Zero()) { 0 -> Twice(\"ab\"), _ -> Name() };"
          " Console.Println(\"x\");",
          "x\n",
          "" },
        // A string is a subject of match and of `is`, matched by the
        // characters it holds; the subject is released after the match.
        { "Console.Println(match (Name()) { \"x\" -> 1,"
          " \"Tala\" -> 2, _ -> 3 });",
          "2\n",
          "" },
        { "Console.Println(match (Twice(\"ab\")) { \"ab\" -> 1,"
          " \"abab\" -> 2, _ -> 3 });",
          "2\n",
          "" },
        { "Console.Println(match (Name()) { \"x\" -> \"no\","
          " String other -> \"is \" + other });",
          "is Tala\n",
          "" },
        { "match (Fizz(3)), (Fizz(5)) { (\"Fizz\"), (\"Buzz\") ->"
          " { Console.Println(\"both\"); },"
          " _, _ -> { Console.Println(\"none\"); } }",
          "both\n",
          "" },
        { "int t = 0; for (int i = 1; i < 16; i += 1) { t += match (Fizz(i))"
          " { \"Fizz\" -> 1, \"Buzz\" -> 10, \"FizzBuzz\" -> 100,"
          " _ -> 0 }; } Console.Println(t);",
          "124\n",
          "" },
        { "Console.Println(Name() is \"Tala\");"
          " Console.Println(Name() is not \"Tala\");",
          "true\nfalse\n",
          "" },
        { "Console.Println(Twice(\"ab\") is \"ab\" or \"abab\");",
          "true\n",
          "" },
        { "String s = Fizz(3); if (s is \"Fizz\" && Name() is not \"x\")"
          " { Console.Println(\"ok\"); }",
          "ok\n",
          "" },
        // Names written through the namespace and the type.
        { "Console.Println(Fuzz.Program.Half(8));", "4\n", "" },
        { "auto f = Program::Log; int x = f(1); Console.Println(9);",
          "1\n9\n",
          "" },
        { "auto f = Fuzz.Program::Half; Console.Println(f(10));", "5\n", "" },
        // A string that is made and never written is released as well.
        { "String t = Console.Format(\"%d\", 1); Console.Println(\"x\");",
          "x\n",
          "" },
        // Loops, branches and methods.
        { "for (int i = 0; i < 3; i += 1) { Console.Print(i); }", "012", "" },
        { "Greet(\"Ada\"); Greet(\"Alan\");",
          "Hello, Ada!\nHello, Alan!\n",
          "" },
        { "Console.Println(Fizz(3)); Console.Println(Fizz(5));"
          " Console.Println(Fizz(15)); Console.Println(Fizz(7));",
          "Fizz\nBuzz\nFizzBuzz\n7\n",
          "" },
        // Output is an effect: it happens where it is written.
        { "int x = Log(1); Console.Println(2);", "1\n2\n", "" },
        { "int x = Log(1); int y = Log(2); Console.Println(y + x);",
          "1\n2\n3\n",
          "" },
        { "Console.Println(Pick(0, Log(5)));", "5\n7\n", "" },
        { "Console.Printf(\"%d %d\", Log(1), Log(2));", "1\n2\n1 2", "" },
        { "Console.Printf(\"%*d\", Log(3), Log(4));", "3\n4\n  4", "" },
        { "Console.Println(\"a\" + Log(1) + Log(2));", "1\n2\na12\n", "" },
        { "int v = Zero() > 0 ? Log(1) : Log(2);", "2\n", "" },
        { "auto say = \\(int v) -> Log(v); int x = say(1);"
          " Console.Println(9);",
          "1\n9\n",
          "" },
        // A value that only computes is still computed by need.
        { "int z = 1 / Zero(); Console.Println(\"ok\");", "ok\n", "" },
        { "int z = 8 / Zero(); Console.Println(Pick(0, z));", "7\n", "" },
    };

    /// The expected text with each line feed as the line terminator of the
    /// platform.
    [[nodiscard]] auto
    OnPlatform(std::string_view expected) -> std::string
    {
        std::string text;
        for (const auto character : expected)
            if (character == '\n')
            {
#ifdef _WIN32
                text += "\r\n";
#else
                text += '\n';
#endif
            }
            else
            {
                text += character;
            }
        return text;
    }

    [[nodiscard]] auto
    Program(std::string_view body) -> std::string
    {
        std::string program = "namespace Fuzz;\nclass Program {\n";
        program += kHelpers;
        program += "    public static int Evaluate() {\n        ";
        program += body;
        program += "\n        return 0;\n    }\n}\n";
        return program;
    }

    int
    Smoke()
    {
        std::size_t index = 0U;
        for (const auto &consoleCase : kCases)
        {
            llvm::errs() << "Console execution " << ++index << " of "
                         << std::size(kCases) << ": " << consoleCase.body
                         << '\n';
            const auto before = Aarc::LiveAllocations();
            Captured captured;
            Console::SetSink(Receive, &captured);
            // Both pipeline modes run the program, so everything is written
            // twice: once by the unoptimized code and once by the optimized.
            Progmasoft::Tala::Fuzzing::ExerciseExpectedValue(
                Program(consoleCase.body),
                0);
            Console::SetSink(nullptr, nullptr);
            const auto output = OnPlatform(consoleCase.output);
            const auto error = OnPlatform(consoleCase.error);
            if (captured.output != output + output
                || captured.error != error + error)
            {
                llvm::errs()
                    << "console case wrote the wrong text\n"
                    << "  expected output, twice: " << output << '\n'
                    << "  written output:         " << captured.output << '\n'
                    << "  expected error, twice:  " << error << '\n'
                    << "  written error:          " << captured.error << '\n';
                return 1;
            }
            const auto after = Aarc::LiveAllocations();
            if (after != before)
            {
                llvm::errs() << "console case left " << (after - before)
                             << " AARC allocation(s) behind\n";
                return 1;
            }
        }
        return 0;
    }
} // namespace

int
main()
{
    return Progmasoft::Tala::Support::RunOnCompilerStack([] {
        return Smoke();
    });
}
