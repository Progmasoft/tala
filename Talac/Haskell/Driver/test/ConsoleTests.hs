-- SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
-- SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-1.1

{- | Console output, strings and the output format grammar.

@Spec\/StandardLibrary\/IO\/ConsoleIO.tala@ specifies the console. A program
writes with @Console.Print@, @Console.Println@, @Console.Printf@ and
@Console.Printfn@, to standard error with @Console.Error@ and its three
siblings, and builds a string with @Console.Format@. A format is a
compile-time string, checked against its arguments when the program is
compiled: a conversion that does not exist, a flag a conversion does not
take, a missing argument and an argument of the wrong type are errors of the
program and not of a run.

Every program here is run in the reference Core evaluator, on the Core the
frontend lowered and on the Core the optimizer left, and what it wrote is
compared with a string written by hand. The line terminator of the
reference is a line feed.

Output is an effect. The second half of this module holds what follows from
that under evaluation by need: an expression that writes is evaluated where
it stands and in the order it is written, whether or not its value is ever
needed, while a value that only computes is still computed by need.
-}
module ConsoleTests (consoleTests) where

import CoreInterpreter
import Data.List (isInfixOf)
import Progmasoft.Tala.Compiler
import Progmasoft.Tala.Core
import Progmasoft.Tala.Core.CorePrep.Verifier
import Progmasoft.Tala.Core.Verifier
import Progmasoft.Tala.Diagnostic

consoleTests :: [(String, Bool)]
consoleTests =
    concat
        [ [ ("unoptimized Core writes " ++ show expected ++ " for " ++ body, written artifactCore body == Just (expected, ""))
          , ("optimized Core writes " ++ show expected ++ " for " ++ body, written artifactOptimizedCore body == Just (expected, ""))
          , ("every stage verifies " ++ body, verifies body)
          ]
        | (body, expected) <- outputs
        ]
        ++ [ ("standard error receives " ++ show expected ++ " for " ++ body, written artifactCore body == Just ("", expected))
           | (body, expected) <- errors
           ]
        ++ [ ("rejected with " ++ code ++ ": " ++ body, rejectedWith code body)
           | (body, code) <- rejections
           ]
        ++ [ ("both streams keep their own text", written artifactCore mixed == Just ("ac", "b\n"))
           , ("the optimizer keeps both streams", written artifactOptimizedCore mixed == Just ("ac", "b\n"))
           , -- A program that writes nothing has no runtime call in it.
             ("a program without output has no runtime call", not (mentions "CoreRuntimeCall" artifactCore "int x = 1;"))
           , ("a write is a runtime call", mentions "CoreRuntimeCall" artifactCore "Console.Print(\"a\");")
           -- The equality primitive on two strings would compare objects.
           , ("a string pattern of is is not the equality primitive", not (mentions "CoreEqual" artifactCore "Console.Println(Name() is \"x\");"))
           , ("a string pattern of match is not the equality primitive", not (mentions "CoreEqual" artifactCore "Console.Println(match (Name()) { \"x\" -> 1, _ -> 2 });"))
           , ("a string is not ordered by a pattern", rejectedWith "TAT0023" "bool b = Name() is > \"A\";")
           , ("a string is not matched by a number in is", rejectedWith "TAT0021" "bool b = Name() is 5;")
           , -- The optimizer may not drop a write whose result nothing uses:
             -- the write is the point.
             ("the optimizer keeps a write", mentions "CoreRuntimeCall" artifactOptimizedCore "Console.Print(\"a\");")
           , ("the optimizer keeps a write in a method nothing reads the result of", written artifactOptimizedCore "Log(4);" == Just ("4\n", ""))
           , -- A value that only computes is still by need beside output.
             ("a value that is never needed is not computed beside output", written artifactCore unusedFailure == Just ("ok\n", ""))
           , ("the same holds after optimization", written artifactOptimizedCore unusedFailure == Just ("ok\n", ""))
           , -- A binding whose initializer writes has no flag: it is not deferred.
             ("a binding that writes is not deferred", not (mentions "$known" artifactCore "int x = Log(1); Console.Println(2);"))
           , ("a binding that only computes is deferred as before", mentions "$known" artifactCore "int x = Half(8); if (Zero() > 0) { Console.Println(x); }")
           , -- An argument that writes is not suspended; one that only
             -- computes still is.
             ("an argument that writes is not suspended", not (mentions "CoreMemoize" artifactCore "Console.Println(Pick(0, Log(5)));"))
           , ("an argument that only computes is suspended as before", mentions "CoreMemoize" artifactCore "Console.Println(Pick(0, 8 / Zero()));")
           , -- A class of the program named Console is the program's own.
             ("a class named Console shadows the console", shadowed)
           ]
    where
        mixed = "Console.Print(\"a\"); Console.Errorln(\"b\"); Console.Print(\"c\");"
        unusedFailure = "int z = 1 / Zero(); Console.Println(\"ok\");"

{- | Programs and what they write to standard output. The body is the body of
@Main@; the helpers are the methods of 'program'.
-}
outputs :: [(String, String)]
outputs =
    -- Plain output. Print writes the text; Println ends the line after it.
    [ ("Console.Print(\"a\"); Console.Print(\"b\");", "ab")
    , ("Console.Println(\"Hello\");", "Hello\n")
    , ("Console.Println(\"\");", "\n")
    , ("Console.Print(\"\");", "")
    , ("Console.Println(\"one\"); Console.Println(\"two\");", "one\ntwo\n")
    , ("System.Console.Println(\"qualified\");", "qualified\n")
    , -- A percent sign has no meaning outside a format.
      ("Console.Println(\"%d\");", "%d\n")
    , ("Console.Println(\"100%\");", "100%\n")
    , -- A value that is not a string is written as text.
      ("Console.Println(42);", "42\n")
    , ("Console.Println(0);", "0\n")
    , ("Console.Println(0 - 7);", "-7\n")
    , ("Console.Println(true);", "true\n")
    , ("Console.Println(false);", "false\n")
    , ("Console.Println('x');", "x\n")
    , ("Console.Println(Half(10));", "5\n")
    , ("int n = 9223372036854775807; Console.Println(n);", "9223372036854775807\n")
    , ("uint u = 18446744073709551615; Console.Println(u);", "18446744073709551615\n")
    , ("byte small = 100; Console.Println(small);", "100\n")
    , ("ushort medium = 65535; Console.Println(medium);", "65535\n")
    , -- A string is a value: bound, passed, returned.
      ("String s = \"kept\"; Console.Println(s);", "kept\n")
    , ("Console.Println(Name());", "Tala\n")
    , ("Console.Println(Twice(\"ab\"));", "abab\n")
    , -- + joins two strings, and writes a value that is not one as text.
      ("Console.Println(\"Hello from \" + \"Tala\" + \"!\");", "Hello from Tala!\n")
    , ("String language = \"Tala\"; Console.Println(\"Hello from \" + language + \"!\");", "Hello from Tala!\n")
    , ("Console.Println(\"n=\" + 5);", "n=5\n")
    , ("Console.Println(5 + \"n\");", "5n\n")
    , ("Console.Println(\"b=\" + true);", "b=true\n")
    , ("Console.Println(\"c=\" + 'z');", "c=z\n")
    , ("Console.Println(\"\" + (1 + 2));", "3\n")
    , -- + associates to the left: the string takes the 1, then the 2.
      ("Console.Println(\"a\" + 1 + 2);", "a12\n")
    , ("Console.Println(1 + 2 + \"a\");", "3a\n")
    , ("uint u = 7; Console.Println(\"u=\" + u);", "u=7\n")
    , ("Console.Println(\"\" + \"\");", "\n")
    , ("String t = \"x\"; t += \"y\"; t += 3; Console.Println(t);", "xy3\n")
    , ("String t = \"\"; for (int i = 0; i < 4; i += 1) { t += i; } Console.Println(t);", "0123\n")
    , -- Strings are compared by what they hold.
      ("Console.Println(\"a\" == \"a\");", "true\n")
    , ("Console.Println(\"a\" == \"b\");", "false\n")
    , ("Console.Println(\"a\" \\= \"b\");", "true\n")
    , ("Console.Println(\"a\" \\= \"a\");", "false\n")
    , ("String a = \"ab\"; String b = \"a\" + \"b\"; Console.Println(a == b);", "true\n")
    , ("String a = \"ab\"; String b = \"a\" + \"c\"; Console.Println(a == b);", "false\n")
    , ("Console.Println(\"\" == \"\");", "true\n")
    , ("Console.Println(\"a\" == \"ab\");", "false\n")
    , ("if (Name() == \"Tala\") { Console.Println(\"same\"); } else { Console.Println(\"other\"); }", "same\n")
    , -- Printf writes its format; Printfn ends the line after it.
      ("Console.Printf(\"plain\");", "plain")
    , ("Console.Printfn(\"plain\");", "plain\n")
    , ("Console.Printf(\"\");", "")
    , ("Console.Printfn(\"\");", "\n")
    , ("Console.Printf(\"%d\", 42);", "42")
    , ("Console.Printfn(\"%d\", 42);", "42\n")
    , ("Console.Printf(\"Count: %d\", 3);", "Count: 3")
    , ("Console.Printf(\"%d and %d\", 1, 2);", "1 and 2")
    , ("Console.Printfn(\"gcd(%d, %d) = %d\", 1071, 462, 21);", "gcd(1071, 462) = 21\n")
    , -- %d: a signed integer in decimal.
      ("Console.Printf(\"%d\", 0 - 255);", "-255")
    , ("Console.Printf(\"%5d|\", 42);", "   42|")
    , ("Console.Printf(\"%-5d|\", 42);", "42   |")
    , ("Console.Printf(\"%05d\", 42);", "00042")
    , ("Console.Printf(\"%05d\", 0 - 42);", "-0042")
    , ("Console.Printf(\"%08d\", 123);", "00000123")
    , ("Console.Printf(\"%+d\", 42);", "+42")
    , ("Console.Printf(\"%+d\", 0 - 42);", "-42")
    , ("Console.Printf(\"% d\", 42);", " 42")
    , ("Console.Printf(\"%2d\", 12345);", "12345")
    , -- The ' flag groups the integer digits in threes with apostrophes.
      ("Console.Printf(\"%'d\", 1234567);", "1'234'567")
    , ("Console.Printf(\"%'d\", 123);", "123")
    , ("Console.Printf(\"%'d\", 1234);", "1'234")
    , ("Console.Printf(\"%'d\", 0 - 1234567);", "-1'234'567")
    , ("byte small = 0 - 100; Console.Printf(\"%d\", small);", "-100")
    , -- %x: hexadecimal. A negative number is a minus sign and its
      -- magnitude, never the bit pattern of its representation.
      ("Console.Printf(\"%x\", 255);", "ff")
    , ("Console.Printf(\"%x\", 0 - 255);", "-ff")
    , ("Console.Printf(\"%#x\", 255);", "0xff")
    , ("Console.Printf(\"%#x\", 0 - 255);", "-0xff")
    , ("Console.Printf(\"%08x\", 48879);", "0000beef")
    , ("Console.Printf(\"%#08x\", 255);", "0x0000ff")
    , ("uint u = 4294967295; Console.Printf(\"%x\", u);", "ffffffff")
    , ("Console.Printf(\"%x\", 0);", "0")
    , -- %u: an unsigned integer.
      ("uint u = 42; Console.Printf(\"%u\", u);", "42")
    , ("Console.Printf(\"%u\", 42);", "42")
    , ("ubyte tiny = 255; Console.Printf(\"%u\", tiny);", "255")
    , ("uint u = 1234567; Console.Printf(\"%'u\", u);", "1'234'567")
    , -- %s and %c.
      ("Console.Printf(\"%s\", \"abc\");", "abc")
    , ("Console.Printf(\"%10s|\", \"abc\");", "       abc|")
    , ("Console.Printf(\"%-10s|\", \"abc\");", "abc       |")
    , ("Console.Printf(\"%.2s\", \"abcdef\");", "ab")
    , ("Console.Printf(\"%.5s\", \"abc\");", "abc")
    , ("Console.Printf(\"%5.1s|\", \"abc\");", "    a|")
    , ("Console.Printf(\"%s: %d\", \"total\", 7);", "total: 7")
    , ("Console.Printf(\"%s\", Name());", "Tala")
    , ("Console.Printf(\"%c\", 'q');", "q")
    , ("Console.Printf(\"%3c|\", 'q');", "  q|")
    , ("Console.Printf(\"%-3c|\", 'q');", "q  |")
    , -- %b: a Boolean.
      ("Console.Printf(\"%b\", true);", "true")
    , ("Console.Printf(\"%b\", 1 > 2);", "false")
    , ("Console.Printf(\"%6b|\", false);", " false|")
    , ("Console.Printf(\"%-6b|\", true);", "true  |")
    , -- %% is a percent sign and %n the line terminator; neither takes an
      -- argument.
      ("Console.Printf(\"100%%\");", "100%")
    , ("Console.Printf(\"%d%%\", 50);", "50%")
    , ("Console.Printf(\"A%nB\");", "A\nB")
    , ("Console.Printf(\"%n\");", "\n")
    , -- %f: a fixed number of digits after the point, six unless a
      -- precision says otherwise; a tie rounds to the even digit.
      ("Console.Printf(\"%f\", 12.5);", "12.500000")
    , ("Console.Printf(\"%.2f\", 12.5);", "12.50")
    , ("Console.Printf(\"%.0f\", 2.5);", "2")
    , ("Console.Printf(\"%.0f\", 3.5);", "4")
    , ("Console.Printf(\"%.1f\", 0.25);", "0.2")
    , ("Console.Printf(\"%.1f\", 0.75);", "0.8")
    , ("Console.Printf(\"%.3f\", 3.14159);", "3.142")
    , ("Console.Printf(\"%10.3f|\", 3.14159);", "     3.142|")
    , ("Console.Printf(\"%-10.3f|\", 3.14159);", "3.142     |")
    , ("Console.Printf(\"%010.3f\", 3.14159);", "000003.142")
    , ("Console.Printf(\"%+.1f\", 1.5);", "+1.5")
    , ("Console.Printf(\"%'.2f\", 1234567.5);", "1'234'567.50")
    , ("Console.Printf(\"%.2f\", 0.0);", "0.00")
    , -- The digits are those of the binary number, not of the literal.
      ("Console.Printf(\"%.20f\", 0.1);", "0.10000000000000000555")
    , ("Console.Printf(\"%.1f\", 1000000.0);", "1000000.0")
    , ("float price = 19.99; Console.Printfn(\"Price: %.2f\", price);", "Price: 19.99\n")
    , -- A width or a precision written as * is the int argument before
      -- the value.
      ("Console.Printf(\"%*d|\", 5, 42);", "   42|")
    , ("Console.Printf(\"%-*d|\", 5, 42);", "42   |")
    , ("Console.Printf(\"%*s|\", 6, \"ab\");", "    ab|")
    , ("Console.Printf(\"%.*f\", 2, 3.14159);", "3.14")
    , ("Console.Printf(\"%*.*f|\", 8, 2, 3.14159);", "    3.14|")
    , ("int width = 4; Console.Printf(\"%*d|\", width, 7);", "   7|")
    , -- Console.Format applies a format and writes nothing.
      ("String t = Console.Format(\"%d-%d\", 1, 2); Console.Print(t);", "1-2")
    , ("String t = Console.Format(\"Name: %s, Age: %d\", \"Ada\", 36); Console.Println(t);", "Name: Ada, Age: 36\n")
    , ("String t = Console.Format(\"plain\"); Console.Print(t + \"!\");", "plain!")
    , ("Console.Print(Console.Format(\"%05d\", 42) + Console.Format(\"%x\", 255));", "00042ff")
    , ("String t = Console.Format(\"%d\", 1); Console.Println(\"x\");", "x\n")
    , -- Output in loops, branches and methods.
      ("for (int i = 0; i < 3; i += 1) { Console.Print(i); }", "012")
    , ("for (int i = 1; i <= 3; i += 1) { Console.Printfn(\"%d squared is %d\", i, i * i); }", "1 squared is 1\n2 squared is 4\n3 squared is 9\n")
    , ("if (Half(4) == 2) { Console.Println(\"yes\"); } else { Console.Println(\"no\"); }", "yes\n")
    , ("Greet(\"Ada\"); Greet(\"Alan\");", "Hello, Ada!\nHello, Alan!\n")
    , ("Console.Println(Fizz(3)); Console.Println(Fizz(5)); Console.Println(Fizz(15)); Console.Println(Fizz(7));", "Fizz\nBuzz\nFizzBuzz\n7\n")
    , -- Output is an effect: it happens where it is written and in the
      -- order it is written, whether or not a value is needed.
      ("int x = Log(1); Console.Println(2);", "1\n2\n")
    , ("int x = Log(1); int y = Log(2); Console.Println(y + x);", "1\n2\n3\n")
    , ("int x = Log(1) + Log(2);", "1\n2\n")
    , ("Console.Println(Pick(0, Log(5)));", "5\n7\n")
    , ("Console.Println(Pick(1, Log(5)));", "5\n5\n")
    , ("Console.Printf(\"%d %d\", Log(1), Log(2));", "1\n2\n1 2")
    , -- The width of a conversion is written before its value and is
      -- evaluated before it.
      ("Console.Printf(\"%*d\", Log(3), Log(4));", "3\n4\n  4")
    , ("Console.Println(\"a\" + Log(1) + Log(2));", "1\n2\na12\n")
    , ("_ = Log(8);", "8\n")
    , ("Log(8);", "8\n")
    , ("int v = Zero() > 0 ? Log(1) : Log(2);", "2\n")
    , ("bool both = Log(0) > 0 && Log(1) > 0;", "0\n")
    , ("auto say = \\(int v) -> Log(v); int x = say(1); Console.Println(9);", "1\n9\n")
    , ("int total = 0; for (int i = 0; i < 3; i += 1) { total += Log(i); } Console.Println(total);", "0\n1\n2\n3\n")
    , ("int x = Twofold(3); Console.Println(\"after\");", "3\n3\nafter\n")
    , -- A callable may write itself, and reads what it captured.
      ("auto say = \\(int v) -> Console.Println(v); say(4); say(5);", "4\n5\n")
    , ("auto say = \\(String s) -> Console.Printfn(\"<%s>\", s); say(\"a\");", "<a>\n")
    , ("int base = 3; auto say = \\(int v) -> { Console.Println(v + base); return v; }; int x = say(1); Console.Println(\"end\");", "4\nend\n")
    , -- A value that only computes is still computed by need.
      ("int z = 1 / Zero(); Console.Println(\"ok\");", "ok\n")
    , ("int z = 8 / Zero(); Console.Println(Pick(0, z));", "7\n")
    , ("String s = \"x\"; int z = 8 / Zero(); Console.Println(s);", "x\n")
    , -- Strings that callables take, capture, make and return.
      ("auto greet = \\(String who) -> \"Hi \" + who; Console.Println(greet(\"Ada\"));", "Hi Ada\n")
    , ("String prefix = Name() + \": \"; auto label = \\(int n) -> prefix + n; Console.Println(label(1)); Console.Println(label(2));", "Tala: 1\nTala: 2\n")
    , ("auto twice = \\(int v) -> { Console.Printf(\"%d,\", v); return v * 2; }; Console.Println(twice(twice(1)));", "1,2,4\n")
    , ("auto make = \\(int n) -> Console.Format(\"<%03d>\", n); String all = \"\"; for (int i = 0; i < 3; i += 1) { all += make(i); } Console.Println(all);", "<000><001><002>\n")
    , ("String kept = Twice(\"ab\"); auto never = \\(int n) -> kept + n; Console.Println(\"x\");", "x\n")
    , -- A method is a callable value: it writes where its call stands.
      ("auto f = Log; int x = f(1); Console.Println(9);", "1\n9\n")
    , -- Appending makes a new string; another name keeps the old one.
      ("String s = \"a\"; String t = s; s += \"b\"; Console.Println(s + t);", "aba\n")
    , ("String s = \"\"; for (int i = 0; i < 5; i += 1) { String old = s; s += i; if (old == s) { s += \"!\"; } } Console.Println(s);", "01234\n")
    , -- String operations in arguments that are and are not needed.
      ("Console.Println(Pick(1, Half(8)) + Name());", "4Tala\n")
    , ("String made = Twice(Name() + \"!\"); Console.Println(Pick(0, 8 / Zero()));", "7\n")
    , ("Console.Println(Console.Format(\"[%s]\", Console.Format(\"%5s\", Console.Format(\"%d\", 42))));", "[   42]\n")
    , ("Console.Println(Twice(Twice(\"ab\")) == \"abababab\");", "true\n")
    , -- A conditional selects one of two strings; the other is never made.
      ("String s = Zero() > 0 ? \"a\" : \"b\"; Console.Println(s);", "b\n")
    , ("Console.Println(Zero() == 0 ? Name() : Twice(\"x\"));", "Tala\n")
    , ("String a = \"x\"; String b = \"y\"; String c = Zero() > 0 ? a : b; Console.Println(c + a + b);", "yxy\n")
    , ("Console.Println(Zero() > 0 ? \"a\" : Zero() == 0 ? \"b\" : \"c\");", "b\n")
    , ("String s = Zero() > 0 ? \"\" + Log(1) : \"\" + Log(2); Console.Println(s);", "2\n2\n")
    , ("String s = \"\"; for (int i = 0; i < 4; i += 1) { s += i % 2 == 0 ? \"e\" : \"o\"; } Console.Println(s);", "eoeo\n")
    , ("Console.Println(\"<\" + (Zero() == 0 ? \"yes\" : \"no\") + \">\");", "<yes>\n")
    , ("Greet(Zero() == 0 ? Name() : \"nobody\");", "Hello, Tala!\n")
    , ("String s = \"keep\"; s = Zero() > 0 ? \"lost\" : s; Console.Println(s);", "keep\n")
    , -- A match, an if used as a value and a loop yield strings the same
      -- way: one is selected, and the others are never made.
      ("String s = match (Zero()) { 0 -> \"zero\", 1 -> \"one\", _ -> \"many\" }; Console.Println(s);", "zero\n")
    , ("String s = match (Half(8)) { 0 -> \"zero\", int n if n > 3 -> \"big \" + n, _ -> \"small\" }; Console.Println(s);", "big 4\n")
    , ("String s = if (Zero() > 0) { \"pos\" } else { Name() + \"!\" }; Console.Println(s);", "Tala!\n")
    , ("int i = 0; String s = while (true) { i += 1; if (i > 2) { break \"done\" + i; } }; Console.Println(s);", "done3\n")
    , ("Console.Println(match (Zero()) { 0 -> Name(), _ -> \"x\" } + (if (Zero() == 0) { \"a\" } else { \"b\" }));", "Talaa\n")
    , ("String s = \"k\"; s = match (Zero()) { 1 -> \"lost\", _ -> s }; Console.Println(s);", "k\n")
    , ("String s = match (Zero()) { 0 -> \"\" + Log(1), _ -> \"\" + Log(2) }; Console.Println(s);", "1\n1\n")
    , ("String s = \"\"; for (int i = 0; i < 4; i += 1) { s += match (i % 3) { 0 -> \"a\", 1 -> \"b\", _ -> \"c\" }; } Console.Println(s);", "abca\n")
    , ("Greet(match (Zero()) { 0 -> Name(), _ -> \"nobody\" });", "Hello, Tala!\n")
    , ("String s = match (Zero()) { 0 -> match (Half(2)) { 1 -> \"inner\", _ -> \"other\" }, _ -> \"outer\" }; Console.Println(s);", "inner\n")
    , -- A string is a subject of match and of `is`. It is matched by the
      -- characters it holds: none of these subjects is the object of the
      -- literal it is compared with.
      ("Console.Println(match (Name()) { \"x\" -> 1, \"Tala\" -> 2, _ -> 3 });", "2\n")
    , ("Console.Println(match (Twice(\"ab\")) { \"ab\" -> 1, \"abab\" -> 2, _ -> 3 });", "2\n")
    , ("Console.Println(match (Fizz(15)) { \"Fizz\" -> 3, \"Buzz\" -> 5, \"FizzBuzz\" -> 15, _ -> 0 });", "15\n")
    , ("Console.Println(match (Name()) { \"x\" -> \"no\", String other if other == Twice(\"a\") -> \"twice\", String other -> \"is \" + other });", "is Tala\n")
    , ("match (Fizz(3)), (Fizz(5)) { (\"Fizz\"), (\"Buzz\") -> { Console.Println(\"both\"); }, _, _ -> { Console.Println(\"none\"); } }", "both\n")
    , ("match (Fizz(3)), (Fizz(7)) { (\"Fizz\"), (\"Buzz\") -> { Console.Println(\"both\"); }, _, _ -> { Console.Println(\"none\"); } }", "none\n")
    , ("int t = 0; for (int i = 1; i < 16; i += 1) { t += match (Fizz(i)) { \"Fizz\" -> 1, \"Buzz\" -> 10, \"FizzBuzz\" -> 100, _ -> 0 }; } Console.Println(t);", "124\n")
    , ("Console.Println(Name() is \"Tala\");", "true\n")
    , ("Console.Println(Name() is not \"Tala\");", "false\n")
    , ("Console.Println(Twice(\"ab\") is \"ab\" or \"abab\");", "true\n")
    , ("Console.Println(Twice(\"ab\") is \"ab\" or \"ba\");", "false\n")
    , ("Console.Println(Name() is == \"Tala\"); Console.Println(Name() is \\= \"Tala\");", "true\nfalse\n")
    , ("String s = Fizz(3); if (s is \"Fizz\" && Name() is not \"x\") { Console.Println(\"ok\"); }", "ok\n")
    ]

-- | Programs and what they write to standard error.
errors :: [(String, String)]
errors =
    [ ("Console.Error(\"e\");", "e")
    , ("Console.Errorln(\"failed\");", "failed\n")
    , ("Console.Error(\"a\"); Console.Errorln(\"b\");", "ab\n")
    , ("Console.Errorf(\"Code: %d\", 7);", "Code: 7")
    , ("Console.Errorfn(\"Code: %d\", 7);", "Code: 7\n")
    , ("Console.Errorln(404);", "404\n")
    , ("System.Console.Errorln(\"q\");", "q\n")
    ]

-- | Programs the type checker rejects, with the code it reports.
rejections :: [(String, String)]
rejections =
    -- The console has the methods the specification gives it.
    [ ("Console.Shout(\"x\");", "TAT0071")
    , ("Console.println(\"x\");", "TAT0071")
    , ("System.Console.Nothing();", "TAT0071")
    , -- Print takes one value.
      ("Console.Print();", "TAT0072")
    , ("Console.Println();", "TAT0072")
    , ("Console.Print(\"a\", \"b\");", "TAT0072")
    , ("Console.Printf();", "TAT0072")
    , ("Console.Format();", "TAT0072")
    , -- What cannot be written as text.
      ("auto f = \\(int v) -> v; Console.Println(f);", "TAT0073")
    , ("auto f = \\(int v) -> v; String s = \"a\" + f;", "TAT0073")
    , -- A format is a string literal.
      ("String f = \"%d\"; Console.Printf(f, 1);", "TAT0074")
    , ("Console.Printf(Name());", "TAT0074")
    , ("Console.Printf(\"%d\" + \"%d\", 1, 2);", "TAT0074")
    , ("Console.Format(42);", "TAT0074")
    , -- A conversion that does not exist, or is not finished.
      ("Console.Printf(\"%q\", 1);", "TAT0075")
    , ("Console.Printf(\"%\");", "TAT0075")
    , ("Console.Printf(\"abc%\");", "TAT0075")
    , ("Console.Printf(\"%5\");", "TAT0075")
    , ("Console.Printf(\"%.d\", 1);", "TAT0075")
    , ("Console.Printf(\"%D\", 1);", "TAT0075")
    , ("Console.Printf(\"%i\", 1);", "TAT0075")
    , ("Console.Printf(\"%e\", 1.5);", "TAT0075")
    , ("Console.Printf(\"%1234567890d\", 1);", "TAT0075")
    , -- A flag a conversion does not take, and flags that exclude each
      -- other; examples 16 to 18 of the specification file.
      ("Console.Printf(\"%+s\", \"a\");", "TAT0076")
    , ("Console.Printf(\"%0s\", \"a\");", "TAT0076")
    , ("Console.Printf(\"%#d\", 1);", "TAT0076")
    , ("Console.Printf(\"%'x\", 1);", "TAT0076")
    , ("Console.Printf(\"%-08d\", 1);", "TAT0076")
    , ("Console.Printf(\"%+ d\", 1);", "TAT0076")
    , ("Console.Printf(\"%++d\", 1);", "TAT0076")
    , ("Console.Printf(\"%+u\", 1);", "TAT0076")
    , ("Console.Printf(\"% u\", 1);", "TAT0076")
    , ("Console.Printf(\"%#s\", \"a\");", "TAT0076")
    , ("Console.Printf(\"%'s\", \"a\");", "TAT0076")
    , ("Console.Printf(\"%0c\", 'a');", "TAT0076")
    , ("Console.Printf(\"%+b\", true);", "TAT0076")
    , ("Console.Printf(\"%#f\", 1.5);", "TAT0076")
    , ("Console.Printf(\"%.2d\", 1);", "TAT0076")
    , ("Console.Printf(\"%.2x\", 1);", "TAT0076")
    , ("Console.Printf(\"%.1c\", 'a');", "TAT0076")
    , ("Console.Printf(\"%.1b\", true);", "TAT0076")
    , ("Console.Printf(\"%5%\");", "TAT0076")
    , ("Console.Printf(\"%-n\");", "TAT0076")
    , -- The arguments are the ones the format names, no more and no fewer.
      ("Console.Printf(\"%d\");", "TAT0077")
    , ("Console.Printf(\"%d\", 1, 2);", "TAT0077")
    , ("Console.Printf(\"plain\", 1);", "TAT0077")
    , ("Console.Printf(\"%d %d\", 1);", "TAT0077")
    , ("Console.Printf(\"%*d\", 1);", "TAT0077")
    , ("Console.Printf(\"%*.*f\", 1, 2);", "TAT0077")
    , ("Console.Printf(\"%n\", 1);", "TAT0077")
    , ("Console.Printf(\"%%\", 1);", "TAT0077")
    , ("Console.Format(\"%s\");", "TAT0077")
    , -- An argument has the type its conversion takes. Nothing is
      -- converted for formatting: examples 11 and 12.
      ("uint value = 42; Console.Printf(\"%d\", value);", "TAT0078")
    , ("int value = 42; Console.Printf(\"%u\", value);", "TAT0078")
    , ("int value = 42; Console.Printf(\"%f\", value);", "TAT0078")
    , ("float value = 1.5; Console.Printf(\"%d\", value);", "TAT0078")
    , ("Console.Printf(\"%s\", 42);", "TAT0078")
    , ("Console.Printf(\"%d\", \"text\");", "TAT0078")
    , ("Console.Printf(\"%c\", 65);", "TAT0078")
    , ("Console.Printf(\"%c\", \"a\");", "TAT0078")
    , ("Console.Printf(\"%b\", 1);", "TAT0078")
    , ("Console.Printf(\"%d\", true);", "TAT0078")
    , ("Console.Printf(\"%x\", 1.5);", "TAT0078")
    , ("Console.Printf(\"%x\", \"ff\");", "TAT0078")
    , ("Console.Printf(\"%*d\", true, 1);", "TAT0078")
    , ("Console.Printf(\"%*d\", \"5\", 1);", "TAT0078")
    , ("uint width = 5; Console.Printf(\"%*d\", width, 1);", "TAT0078")
    , ("Console.Printf(\"%.*f\", 1.5, 1.5);", "TAT0078")
    , -- Specified, and not implemented yet.
      ("Console.Printf(\"%A\", 1);", "TAT0079")
    , ("Console.Printf(\"%O\", 1);", "TAT0079")
    , ("Console.Println(1.5);", "TAT0079")
    , ("String s = \"x\" + 1.5;", "TAT0079")
    , ("longint wide = 1; Console.Println(wide);", "TAT0079")
    , ("longint wide = 1; Console.Printf(\"%d\", wide);", "TAT0079")
    , ("ulongint wide = 1; Console.Printf(\"%u\", wide);", "TAT0079")
    , ("double wide = 1.5; Console.Printf(\"%f\", wide);", "TAT0079")
    , ("Console.Stdout();", "TAT0079")
    , ("Console.Stdin();", "TAT0079")
    , ("Console.Stderr();", "TAT0079")
    , -- Strings have + and the two equalities, and no other operator.
      ("String s = \"a\" - \"b\";", "TAT0012")
    , ("String s = \"a\" * 2;", "TAT0012")
    , ("bool b = \"a\" < \"b\";", "TAT0012")
    , -- An immutable string is not appended to.
      ("final String s = \"a\"; s += \"b\";", "TAT0003")
    ]

{- | A class of the program named @Console@ is found before the console of
the language: its method is called, and nothing is written.
-}
shadowed :: Bool
shadowed = case compileSource text of
    Right artifacts ->
        not (any (("CoreRuntimeCall" `isInfixOf`) . show . coreFunctionBody) (coreModuleFunctions (artifactCore artifacts)))
            && (runFunctionWriting 10000 (artifactCore artifacts) "Main" [] == Just (UnitValue, Written "" ""))
    Left _ -> False
    where
        text =
            unlines
                [ "namespace Demo;"
                , "public class Console {"
                , "    public static int Println(_ int value) { return value + 1; }"
                , "}"
                , "public class Program {"
                , "    public static void Main() { int kept = Console.Println(41); }"
                , "}"
                ]

program :: String -> String
program body =
    unlines
        [ "namespace Demo;"
        , "public class Program {"
        , "    public static int Zero() { return 0; }"
        , "    public static int Half(_ int v) { return v / 2; }"
        , "    public static int Pick(_ int flag, _ int value) { if (flag > 0) { return value; } return 7; }"
        , "    public static int Log(_ int v) { Console.Println(v); return v; }"
        , "    public static int Twofold(_ int v) { return Log(v) + Log(v); }"
        , "    public static String Name() { return \"Tala\"; }"
        , "    public static String Twice(_ String s) { return s + s; }"
        , "    public static void Greet(_ String who) { Console.Println(\"Hello, \" + who + \"!\"); }"
        , "    public static String Fizz(_ int n) {"
        , "        if (n % 15 == 0) { return \"FizzBuzz\"; }"
        , "        if (n % 3 == 0) { return \"Fizz\"; }"
        , "        if (n % 5 == 0) { return \"Buzz\"; }"
        , "        return \"\" + n;"
        , "    }"
        , "    public static void Main() {"
        , "        " ++ body
        , "    }"
        , "}"
        ]

compileSource :: String -> Either [Diagnostic] FrontendArtifacts
compileSource text = compileToCorePrep (CompilerInput "console.tala" text)

-- | What @Main@ writes to standard output and to standard error.
written :: (FrontendArtifacts -> CoreModule) -> String -> Maybe (String, String)
written select body = case compileSource (program body) of
    Right artifacts -> case runFunctionWriting 200000 (select artifacts) "Main" [] of
        Just (_, Written output failure) -> Just (output, failure)
        Nothing -> Nothing
    Left _ -> Nothing

rejectedWith :: String -> String -> Bool
rejectedWith code body = case compileSource (program body) of
    Left diagnostics -> any ((== code) . diagnosticCode) diagnostics
    Right _ -> False

-- | Whether the Core of @Main@ mentions the given constructor or generated name.
mentions :: String -> (FrontendArtifacts -> CoreModule) -> String -> Bool
mentions needle select body = case compileSource (program body) of
    Right artifacts ->
        any
            ((needle `isInfixOf`) . show . coreFunctionBody)
            [ function
            | function <- coreModuleFunctions (select artifacts)
            , "Main" `isInfixOf` show (coreFunctionName function)
            ]
    Left _ -> False

verifies :: String -> Bool
verifies body = case compileSource (program body) of
    Right artifacts ->
        verifyCore (artifactCore artifacts) == Right (artifactCore artifacts)
            && verifyCore (artifactOptimizedCore artifacts) == Right (artifactOptimizedCore artifacts)
            && verifyCorePrep (artifactCorePrep artifacts) == Right (artifactCorePrep artifacts)
    Left _ -> False
