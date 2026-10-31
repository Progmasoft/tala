// SPDX-FileCopyrightText: 2026 Progmasoft <support@progmasoft.com>
// SPDX-License-Identifier: MPL-2.0 WITH AdditionRef-Progmasoft-Exception-2.0

#include <Progmasoft/Catch3/Assertions.hpp>
#include <cstddef>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <string_view>
#include <vector>

#include "Talac/Cli/Arguments/Options.hpp"
#include "Talac/Cli/Commands/Commands.hpp"

#ifdef _WIN32
#    ifndef WIN32_LEAN_AND_MEAN
#        define WIN32_LEAN_AND_MEAN
#    endif
#    ifndef NOMINMAX
#        define NOMINMAX
#    endif
#    include <windows.h>
#else
#    include <csignal>
#    include <fcntl.h>
#    include <spawn.h>
#    include <sys/wait.h>
#    include <unistd.h>

// The environment of the process, which a started program inherits. macOS
// does not declare it in a header; glibc does.
// NOLINTNEXTLINE(readability-redundant-declaration)
extern char **environ;
#endif

// Programs built into native executables and run as processes.
//
// Every other execution test runs generated code inside the process that
// compiled it, where the runtime library of the compiler is at hand. A native
// executable has only what was linked into it. These cases build a program
// the way a user does, start the executable, and read its exit status: zero
// for a program that ran to the end of `Main`, and the status of a stopped
// process for a program that needed a value that cannot be computed.
//
// A program checks its own results with `Check`, which divides by zero when
// two numbers differ. A wrong result therefore stops the program, and one
// case confirms that it does, so that the others cannot pass by checking
// nothing.
//
// A program that writes is run with its standard output and standard error
// sent to files, and the bytes it wrote are compared with bytes written by
// hand. That is the only place the whole of console output is tested as a
// user meets it: the runtime library an executable is linked with, the
// import of the system functions it calls, and the bytes on the stream.

namespace
{
    constexpr std::string_view kHeader
        = "namespace Demo;\n"
          "public class Program {\n"
          "    public static int Check(_ int got, _ int expected) {\n"
          "        return 1 / (got == expected ? 1 : 0);\n"
          "    }\n"
          "    public static int Zero(_ int v) { return v - v; }\n"
          "    public static int Pick(_ int flag, _ int value) {\n"
          "        if (flag > 0) { return value; }\n"
          "        return 7;\n"
          "    }\n";

    [[nodiscard]] auto
    Directory() -> std::filesystem::path
    {
        return std::filesystem::temp_directory_path() / "tala-executable-run";
    }

    /// Name of the executable talac writes for a program of this file.
    [[nodiscard]] auto
    ExecutableName(std::string_view name) -> std::string
    {
        return std::string(name) + OutputExtension(BuildOutput::kExecutable);
    }

    /// Writes the program, and gives the status of `talac` asked to emit the
    /// given kind of output from it.
    [[nodiscard]] auto
    Drive(std::string_view emit,
          std::string_view name,
          std::string_view members,
          bool withEntry = true) -> int
    {
        std::filesystem::create_directories(Directory());
        const auto source = Directory() / (std::string(name) + ".tala");
        {
            std::ofstream stream(source, std::ios::binary | std::ios::trunc);
            stream << kHeader << members << "}\n";
            REQUIRE(stream.good());
        }
        std::vector<std::string> storage{ "talac",
                                          source.string(),
                                          "--emit=" + std::string(emit) };
        if (withEntry)
            storage.emplace_back("--entry=Demo.Program");
        std::vector<char *> arguments;
        arguments.reserve(storage.size() + 1U);
        for (auto &argument : storage)
            arguments.push_back(argument.data());
        arguments.push_back(nullptr);
        return Progmasoft::Tala::Cli::Run(static_cast<int>(storage.size()),
                                          arguments.data());
    }

    /// The status of a process that executed an instruction the processor
    /// refuses, which is how generated code stops. Windows reports the
    /// exception. Elsewhere the process is ended by a signal, which is
    /// reported the way a shell reports it, 128 and the signal: the
    /// processor's refusal on x86, and a breakpoint on Arm, whose trap
    /// instruction is one.
#if defined(_WIN32)
    constexpr int kStopped = static_cast<int>(0xC000001DU);
#elif defined(__aarch64__) || defined(__arm64__)
    constexpr int kStopped = 128 + SIGTRAP;
#else
    constexpr int kStopped = 128 + SIGILL;
#endif

    /// Expected output is written here with the line ending of Windows,
    /// which is what a program writes there. Elsewhere a line ends with a
    /// line feed alone, and the expectation is read without the carriage
    /// returns.
    [[nodiscard]] auto
    Lines(std::string_view expected) -> std::string
    {
#ifdef _WIN32
        return std::string(expected);
#else
        std::string result;
        result.reserve(expected.size());
        for (std::size_t index = 0U; index < expected.size(); ++index)
            if (expected[index] != '\r' || index + 1U == expected.size()
                || expected[index + 1U] != '\n')
                result.push_back(expected[index]);
        return result;
#endif
    }

    /// What a process did: how it ended and what it wrote.
    struct Outcome final
    {
        int status{ -1 };
        std::string output;
        std::string error;
    };

    [[nodiscard]] auto
    ReadAll(const std::filesystem::path &path) -> std::string
    {
        std::ifstream stream(path, std::ios::binary);
        return { std::istreambuf_iterator<char>(stream),
                 std::istreambuf_iterator<char>() };
    }

#ifdef _WIN32
    /// A file a child process may write to through an inherited handle.
    [[nodiscard]] auto
    InheritableFile(const std::filesystem::path &path) -> HANDLE
    {
        SECURITY_ATTRIBUTES attributes{};
        attributes.nLength = sizeof(attributes);
        attributes.bInheritHandle = TRUE;
        return CreateFileW(path.c_str(),
                           GENERIC_WRITE,
                           FILE_SHARE_READ,
                           &attributes,
                           CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL,
                           nullptr);
    }

    /// Builds the program into an executable, runs the executable with its
    /// standard streams sent to files, and returns what it wrote.
    [[nodiscard]] auto
    RunCapturing(std::string_view name, std::string_view members) -> Outcome
    {
        REQUIRE(Drive("executable", name, members) == 0);
        const auto executable = Directory() / ExecutableName(name);
        const auto outputPath = Directory() / (std::string(name) + ".out");
        const auto errorPath = Directory() / (std::string(name) + ".err");
        REQUIRE(std::filesystem::is_regular_file(executable));

        auto *output = InheritableFile(outputPath);
        auto *error = InheritableFile(errorPath);
        REQUIRE(output != INVALID_HANDLE_VALUE);
        REQUIRE(error != INVALID_HANDLE_VALUE);

        STARTUPINFOW startup{};
        startup.cb = sizeof(startup);
        startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdInput = nullptr;
        startup.hStdOutput = output;
        startup.hStdError = error;
        PROCESS_INFORMATION process{};
        auto commandLine = L'"' + executable.wstring() + L'"';
        const auto started = CreateProcessW(executable.c_str(),
                                            commandLine.data(),
                                            nullptr,
                                            nullptr,
                                            TRUE,
                                            0,
                                            nullptr,
                                            nullptr,
                                            &startup,
                                            &process);
        CloseHandle(output);
        CloseHandle(error);
        REQUIRE(started != 0);
        CloseHandle(process.hThread);
        REQUIRE(WaitForSingleObject(process.hProcess, 120000U)
                == WAIT_OBJECT_0);
        DWORD status = 0U;
        REQUIRE(GetExitCodeProcess(process.hProcess, &status) != 0);
        CloseHandle(process.hProcess);
        return { static_cast<int>(status),
                 ReadAll(outputPath),
                 ReadAll(errorPath) };
    }
#else
    /// Builds the program into an executable, runs the executable with its
    /// standard streams sent to files, and returns what it wrote.
    [[nodiscard]] auto
    RunCapturing(std::string_view name, std::string_view members) -> Outcome
    {
        REQUIRE(Drive("executable", name, members) == 0);
        const auto executable = Directory() / ExecutableName(name);
        const auto outputPath = Directory() / (std::string(name) + ".out");
        const auto errorPath = Directory() / (std::string(name) + ".err");
        REQUIRE(std::filesystem::is_regular_file(executable));

        posix_spawn_file_actions_t actions{};
        REQUIRE(posix_spawn_file_actions_init(&actions) == 0);
        REQUIRE(posix_spawn_file_actions_addopen(&actions,
                                                 STDOUT_FILENO,
                                                 outputPath.c_str(),
                                                 O_WRONLY | O_CREAT | O_TRUNC,
                                                 0600)
                == 0);
        REQUIRE(posix_spawn_file_actions_addopen(&actions,
                                                 STDERR_FILENO,
                                                 errorPath.c_str(),
                                                 O_WRONLY | O_CREAT | O_TRUNC,
                                                 0600)
                == 0);
        auto program = executable.string();
        std::vector<char *> arguments{ program.data(), nullptr };
        pid_t process{};
        const int spawned = posix_spawn(&process,
                                        program.c_str(),
                                        &actions,
                                        nullptr,
                                        arguments.data(),
                                        environ);
        posix_spawn_file_actions_destroy(&actions);
        REQUIRE(spawned == 0);
        int status{};
        REQUIRE(waitpid(process, &status, 0) == process);
        // A program a signal ended is reported the way `talac run` reports
        // it, so that both ways of running one agree on a status.
        const int reported = WIFEXITED(status)     ? WEXITSTATUS(status)
                             : WIFSIGNALED(status) ? 128 + WTERMSIG(status)
                                                   : -1;
        return { reported, ReadAll(outputPath), ReadAll(errorPath) };
    }
#endif

    /// Builds the program, runs it, and gives the status it ended with.
    [[nodiscard]] auto
    Run(std::string_view name, std::string_view members) -> int
    {
        return RunCapturing(name, members).status;
    }
} // namespace

TEST_CASE("every program of this file passes the checks before code "
          "generation")
{
    CHECK(Drive("metadata",
                "Checked",
                "    public static void Main() { Check(Pick(0, 1), 7); }\n")
          == 0);
    std::filesystem::remove_all(Directory());
}

TEST_CASE("a check writes its record and no executable")
{
    REQUIRE(Drive("metadata",
                  "Quiet",
                  "    public static void Main() {"
                  " Console.Println(\"x\"); }\n")
            == 0);
    std::size_t files = 0U;
    for (const auto &entry : std::filesystem::directory_iterator(Directory()))
    {
        const auto name = entry.path().filename().string();
        CHECK((name == "Quiet.tala" || name == "Quiet.talameta"));
        ++files;
    }
    CHECK(files == 2U);
    const auto record = ReadAll(Directory() / "Quiet.talameta");
    CHECK(record.starts_with("talameta 1\ncompiler "));
    CHECK(record.find("\nentry Demo.Program\n") != std::string::npos);
    CHECK(record.ends_with("Quiet.tala\n"));
    CHECK(record.find('\\') == std::string::npos);
    std::filesystem::remove_all(Directory());
}

TEST_CASE("a check of one source needs no entry and records none")
{
    REQUIRE(Drive("metadata",
                  "Loose",
                  "    public static void Main() {"
                  " Console.Println(\"x\"); }\n",
                  false)
            == 0);
    const auto record = ReadAll(Directory() / "Loose.talameta");
    CHECK(record.starts_with("talameta 1\ncompiler "));
    CHECK(record.find("\nentry ") == std::string::npos);
    CHECK(record.ends_with("Loose.tala\n"));
    // The same source is still refused when it is wrong.
    CHECK(Drive("metadata",
                "LooseWrong",
                "    public static void Main() { int value = true; }\n",
                false)
          != 0);
    CHECK_FALSE(std::filesystem::exists(Directory() / "LooseWrong.talameta"));
    // Building needs the entry as before.
    CHECK(Drive("executable",
                "LooseBuild",
                "    public static void Main() { }\n",
                false)
          == 2);
    std::filesystem::remove_all(Directory());
}

TEST_CASE("a check refuses a program a build would refuse")
{
    CHECK(Drive("metadata",
                "Wrong",
                "    public static void Main() { int value = true; }\n")
          != 0);
    // A program that is refused leaves no record that it was checked.
    CHECK_FALSE(std::filesystem::exists(Directory() / "Wrong.talameta"));
    std::filesystem::remove_all(Directory());
}

TEST_CASE("a program whose Main ends without a return runs to its end")
{
    CHECK(Run("Empty", "    public static void Main() { }\n") == 0);
    CHECK(Run("Falling",
              "    public static void Touch(_ int v) { int w = v + 1; }\n"
              "    public static void Twice(_ int v) {\n"
              "        if (v > 0) { Touch(v); return; }\n"
              "        Touch(v + 1);\n"
              "    }\n"
              "    public static void Main() {\n"
              "        Twice(1);\n"
              "        Twice(0);\n"
              "        for (int i = 0; i < 3; i += 1) { Touch(i); }\n"
              "    }\n")
          == 0);
    std::filesystem::remove_all(Directory());
}

TEST_CASE("a program that checks a wrong result stops")
{
    CHECK(Run("Right", "    public static void Main() { Check(1 + 1, 2); }\n")
          == 0);
    CHECK(Run("Wrong", "    public static void Main() { Check(1 + 1, 3); }\n")
          == kStopped);
    CHECK(Run("WrongLater",
              "    public static void Main() {\n"
              "        Check(Pick(1, 4), 4);\n"
              "        Check(Pick(0, 4), 4);\n"
              "    }\n")
          == kStopped);
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable passes arguments by need")
{
    // A division by zero in an argument the method does not read is never
    // carried out; the same argument, read, is the value it should be.
    CHECK(Run("ByNeed",
              "    public static int Run(_ int a, _ int b) {\n"
              "        return Pick(a, b / a);\n"
              "    }\n"
              "    public static int Pass(_ int flag, _ int value) {\n"
              "        return Pick(flag, value);\n"
              "    }\n"
              "    public static void Main() {\n"
              "        Check(Run(0, 8), 7);\n"
              "        Check(Run(2, 8), 4);\n"
              "        Check(Pass(0, 8 / Zero(3)), 7);\n"
              "        Check(Pass(1, 8 / (Zero(3) + 2)), 4);\n"
              "        int shared = 12 / (Zero(1) + 3);\n"
              "        Check(Pick(1, shared) + shared, 8);\n"
              "    }\n")
          == 0);
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable that needs a quotient by zero stops")
{
    CHECK(Run("Needed",
              "    public static void Main() {\n"
              "        Check(Pick(1, 8 / Zero(3)), 0);\n"
              "    }\n")
          == kStopped);
    CHECK(Run("NeededRemainder",
              "    public static void Main() {\n"
              "        int left = 8 % Zero(3);\n"
              "        Check(left, left);\n"
              "    }\n")
          == kStopped);
    CHECK(Run("NotNeeded",
              "    public static void Main() {\n"
              "        int never = 8 / Zero(3);\n"
              "        Check(Pick(0, never), 7);\n"
              "    }\n")
          == 0);
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable wraps the least integer divided by minus one")
{
    CHECK(Run("Wraps",
              "    public static void Main() {\n"
              "        int least = Zero(1) - 9223372036854775807 - 1;\n"
              "        int minusOne = Zero(1) - 1;\n"
              "        Check(least / minusOne, least);\n"
              "        Check(least % minusOne, 0);\n"
              "    }\n")
          == 0);
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable creates and calls closures")
{
    CHECK(Run("Closures",
              "    public static int Run(_ int a, _ int b) {\n"
              "        auto f = \\(int v) -> v + a;\n"
              "        auto g = \\(int w) -> f(w) * 2;\n"
              "        return g(b);\n"
              "    }\n"
              "    public static void Main() { Check(Run(1, 8), 18); }\n")
          == 0);
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable reuses the memory of the objects it releases")
{
    // Each pass creates objects and releases them. Two million passes hold
    // far more than the executable's memory if nothing is reused, and no
    // more than one pass does if everything is.
    CHECK(Run("ReuseClosures",
              "    public static int Many(_ int rounds) {\n"
              "        int total = 0;\n"
              "        for (int i = 0; i < rounds; i += 1) {\n"
              "            auto add = \\(int v) -> v + i;\n"
              "            total += add(1) - i;\n"
              "        }\n"
              "        return total;\n"
              "    }\n"
              "    public static void Main() {\n"
              "        Check(Many(2000000), 2000000);\n"
              "    }\n")
          == 0);
    CHECK(Run("ReuseArguments",
              "    public static int Many(_ int rounds) {\n"
              "        int total = 0;\n"
              "        for (int i = 0; i < rounds; i += 1) {\n"
              "            total += Pick(i % 2, 10 / (i % 2));\n"
              "        }\n"
              "        return total;\n"
              "    }\n"
              "    public static void Main() {\n"
              "        Check(Many(2000000), 17000000);\n"
              "    }\n")
          == 0);
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable holds many objects at one time")
{
    // Every level of the recursion holds a closure until the levels below
    // it have returned.
    CHECK(Run("Held",
              "    public static int Deep(_ int n) {\n"
              "        auto here = \\(int v) -> v + n;\n"
              "        if (n <= 0) { return here(0); }\n"
              "        return Deep(n - 1) + here(1) - n;\n"
              "    }\n"
              "    public static void Main() { Check(Deep(4000), 4000); }\n")
          == 0);
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable writes to standard output")
{
    // The example program of the repository, as it is written there.
    const auto hello
        = RunCapturing("HelloWorld",
                       "    public static void Main() {\n"
                       "        String language = \"Tala\";\n"
                       "        Console.Println(\"Hello from \" + language"
                       " + \"!\");\n"
                       "    }\n");
    CHECK(hello.status == 0);
    CHECK(hello.output == Lines("Hello from Tala!\r\n"));
    CHECK(hello.error.empty());

    // Print ends no line, Println ends one with the line terminator of the
    // platform, and a line feed written in a string is a line feed.
    const auto lines = RunCapturing("Lines",
                                    "    public static void Main() {\n"
                                    "        Console.Print(\"a\");\n"
                                    "        Console.Print(\"b\");\n"
                                    "        Console.Println(\"\");\n"
                                    "        Console.Println(42);\n"
                                    "        Console.Println(true);\n"
                                    "        Console.Println('x');\n"
                                    "    }\n");
    CHECK(lines.status == 0);
    CHECK(lines.output == Lines("ab\r\n42\r\ntrue\r\nx\r\n"));
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable keeps standard output and standard error apart")
{
    const auto outcome
        = RunCapturing("Streams",
                       "    public static void Main() {\n"
                       "        Console.Print(\"out one, \");\n"
                       "        Console.Errorln(\"error one\");\n"
                       "        Console.Println(\"out two\");\n"
                       "        Console.Errorfn(\"error %d\", 2);\n"
                       "    }\n");
    CHECK(outcome.status == 0);
    CHECK(outcome.output == Lines("out one, out two\r\n"));
    CHECK(outcome.error == Lines("error one\r\nerror 2\r\n"));
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable writes to a file as UTF-8")
{
    // One character of two bytes and one of three, written in the source.
    const auto outcome
        = RunCapturing("Encoded",
                       "    public static void Main() {\n"
                       "        Console.Println(\"\xc3\xa9\xe2\x82\xac\");\n"
                       "        Console.Printf(\"%4s|\", \"\xc3\xa9\");\n"
                       "    }\n");
    CHECK(outcome.status == 0);
    // The width counts characters, not bytes: three spaces before one
    // character of two bytes.
    CHECK(outcome.output == Lines("\xc3\xa9\xe2\x82\xac\r\n   \xc3\xa9|"));
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable applies the conversions of a format")
{
    const auto outcome = RunCapturing(
        "Formats",
        "    public static void Main() {\n"
        "        Console.Printfn(\"gcd(%d, %d) = %d\", 1071, 462, 21);\n"
        "        Console.Printfn(\"%5d|%-5d|%05d\", 42, 42, 0 - 42);\n"
        "        Console.Printfn(\"%+d %'d\", 42, 0 - 1234567);\n"
        "        Console.Printfn(\"%x %#x %x\", 255, 255, 0 - 255);\n"
        "        uint size = 4294967295;\n"
        "        Console.Printfn(\"%u %x\", size, size);\n"
        "        Console.Printfn(\"%10s|%-10s|%.2s\", \"abc\", \"abc\","
        " \"abcdef\");\n"
        "        Console.Printfn(\"%c%3c|%b %6b|\", 'q', 'q', true, false);\n"
        "        Console.Printfn(\"%d%% done%n%s\", 50, \"next\");\n"
        "        Console.Printfn(\"%*d|%.*f|%*.*f|\", 5, 42, 2, 3.14159, 8, 2,"
        " 3.14159);\n"
        "    }\n");
    CHECK(outcome.status == 0);
    CHECK(outcome.output
          == Lines("gcd(1071, 462) = 21\r\n"
                   "   42|42   |-0042\r\n"
                   "+42 -1'234'567\r\n"
                   "ff 0xff -ff\r\n"
                   "4294967295 ffffffff\r\n"
                   "       abc|abc       |ab\r\n"
                   "q  q|true  false|\r\n"
                   "50% done\r\nnext\r\n"
                   "   42|3.14|    3.14|\r\n"));
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable writes floating-point numbers exactly")
{
    const auto outcome = RunCapturing(
        "Floating",
        "    public static void Main() {\n"
        "        Console.Printfn(\"%f\", 12.5);\n"
        "        Console.Printfn(\"%.2f %.0f %.0f\", 12.5, 2.5, 3.5);\n"
        "        Console.Printfn(\"%010.3f|%-10.3f|\", 3.14159, 3.14159);\n"
        "        Console.Printfn(\"%'.2f\", 1234567.5);\n"
        "        Console.Printfn(\"%.20f\", 0.1);\n"
        "        float price = 19.99;\n"
        "        Console.Printfn(\"Price: %.2f\", price);\n"
        "    }\n");
    CHECK(outcome.status == 0);
    CHECK(outcome.output
          == Lines("12.500000\r\n"
                   "12.50 2 4\r\n"
                   "000003.142|3.142     |\r\n"
                   "1'234'567.50\r\n"
                   "0.10000000000000000555\r\n"
                   "Price: 19.99\r\n"));
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable joins and compares strings")
{
    const auto outcome = RunCapturing(
        "Strings",
        "    public static String Twice(_ String s) { return s + s; }\n"
        "    public static void Main() {\n"
        "        String line = \"x\";\n"
        "        line += \"y\";\n"
        "        line += 3;\n"
        "        Console.Println(Twice(line));\n"
        "        Console.Println(\"n=\" + 5 + \" b=\" + true + \" c=\" + "
        "'z');\n"
        "        String first = \"ab\";\n"
        "        String second = \"a\" + \"b\";\n"
        "        Console.Println(first == second);\n"
        "        Console.Println(first \\= second);\n"
        "        Console.Println(first == \"abc\");\n"
        "        String made = Console.Format(\"%05d-%s\", 42, first);\n"
        "        Console.Println(made);\n"
        "    }\n");
    CHECK(outcome.status == 0);
    CHECK(outcome.output
          == Lines("xy3xy3\r\n"
                   "n=5 b=true c=z\r\n"
                   "true\r\nfalse\r\nfalse\r\n"
                   "00042-ab\r\n"));
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable writes where the program says, in the order it "
          "says")
{
    // Output is an effect: a binding that writes is carried out where it
    // stands, and a value that only computes is still computed by need.
    const auto outcome = RunCapturing(
        "Effects",
        "    public static int Log(_ int v) { Console.Println(v);"
        " return v; }\n"
        "    public static void Main() {\n"
        "        int unused = Log(1);\n"
        "        int never = 8 / Zero(3);\n"
        "        Console.Println(Pick(0, Log(5)));\n"
        "        Console.Printf(\"%*d|%n\", Log(3), Log(4));\n"
        "        Console.Println(Pick(0, never));\n"
        "    }\n");
    CHECK(outcome.status == 0);
    CHECK(outcome.output == Lines("1\r\n5\r\n7\r\n3\r\n4\r\n  4|\r\n7\r\n"));
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable has written what came before it stopped")
{
    // The runtime keeps no buffer, so nothing is lost when a program stops.
    const auto outcome
        = RunCapturing("Stopped",
                       "    public static void Main() {\n"
                       "        Console.Println(\"before\");\n"
                       "        Console.Error(\"also before\");\n"
                       "        Check(1, 2);\n"
                       "        Console.Println(\"after\");\n"
                       "    }\n");
    CHECK(outcome.status == kStopped);
    CHECK(outcome.output == Lines("before\r\n"));
    CHECK(outcome.error == "also before");
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable releases the strings it makes")
{
    // Each pass makes and releases several strings. A million passes hold
    // far more than a process may if none is released; the last line shows
    // the loop ran to its end.
    const auto outcome = RunCapturing(
        "Many",
        "    public static void Main() {\n"
        "        int total = 0;\n"
        "        for (int i = 0; i < 1000000; i += 1) {\n"
        "            String text = \"value \" + i;\n"
        "            String made = Console.Format(\"%08d|%s\", i, text);\n"
        "            if (made == text) { total += 1; }\n"
        "            total += 1;\n"
        "        }\n"
        "        Console.Println(total);\n"
        "    }\n");
    CHECK(outcome.status == 0);
    CHECK(outcome.output == Lines("1000000\r\n"));
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable calls a method held as a value where the call "
          "stands")
{
    // A method is a callable value. Nothing reads what the calls return,
    // and both write all the same.
    const auto outcome = RunCapturing(
        "Held",
        "    public static int Log(_ int v) { Console.Println(v);"
        " return v; }\n"
        "    public static int Run(_ (int) -> int f) { return f(3); }\n"
        "    public static void Main() {\n"
        "        auto f = Log;\n"
        "        int first = f(1);\n"
        "        int second = Run(Log);\n"
        "        Console.Println(9);\n"
        "    }\n");
    CHECK(outcome.status == 0);
    CHECK(outcome.output == Lines("1\r\n3\r\n9\r\n"));
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable passes strings through callables")
{
    const auto outcome = RunCapturing(
        "Callables",
        "    public static String Name() { return \"Tala\"; }\n"
        "    public static void Main() {\n"
        "        String prefix = Name() + \": \";\n"
        "        auto label = \\(int n) -> prefix + n;\n"
        "        auto twice = \\(int v) -> { Console.Printf(\"%d,\", v);"
        " return v * 2; };\n"
        "        Console.Println(label(1));\n"
        "        Console.Println(label(twice(twice(1))));\n"
        "        String all = \"\";\n"
        "        for (int i = 0; i < 1000; i += 1) { all += label(i % 10); }\n"
        "        Console.Println(all == \"\");\n"
        "    }\n");
    CHECK(outcome.status == 0);
    CHECK(outcome.output == Lines("Tala: 1\r\n1,2,Tala: 4\r\nfalse\r\n"));
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable that appends keeps the string another name holds")
{
    const auto outcome
        = RunCapturing("Append",
                       "    public static void Main() {\n"
                       "        String s = \"a\";\n"
                       "        String t = s;\n"
                       "        s += \"b\";\n"
                       "        s += 7;\n"
                       "        Console.Println(s + \"|\" + t);\n"
                       "    }\n");
    CHECK(outcome.status == 0);
    CHECK(outcome.output == Lines("ab7|a\r\n"));
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable that shifts by the width of the type stops")
{
    const auto outcome
        = RunCapturing("Shift",
                       "    public static void Main() {\n"
                       "        Console.Println(1 << (Zero(3) + 63) < 0);\n"
                       "        int k = 1 << (Zero(3) + 64);\n"
                       "        Console.Println(k);\n"
                       "        Console.Println(\"after\");\n"
                       "    }\n");
    CHECK(outcome.status == kStopped);
    CHECK(outcome.output == Lines("true\r\n"));
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable that only reports writes nothing to standard "
          "output")
{
    const auto outcome
        = RunCapturing("Report",
                       "    public static void Main() {\n"
                       "        Console.Errorfn(\"%s: %d\", \"code\", 7);\n"
                       "        Console.Error(\"done\");\n"
                       "    }\n");
    CHECK(outcome.status == 0);
    CHECK(outcome.output.empty());
    CHECK(outcome.error == Lines("code: 7\r\ndone"));
    std::filesystem::remove_all(Directory());
}

TEST_CASE("a link leaves only the executable beside the source")
{
    // The import library and the list of names it is made from are made
    // for one link and removed after it.
    REQUIRE(Drive("executable",
                  "Tidy",
                  "    public static void Main() {"
                  " Console.Println(\"x\"); }\n")
            == 0);
    std::size_t executables = 0U;
    for (const auto &entry : std::filesystem::directory_iterator(Directory()))
    {
        const auto extension = entry.path().extension().string();
        CHECK(extension != ".def");
        CHECK(extension != ".lib");
        CHECK(extension != ".obj");
        CHECK(extension != ".o");
        if (entry.path().filename().string() == ExecutableName("Tidy"))
            ++executables;
    }
    CHECK(executables == 1U);
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable selects one of two strings")
{
    // Every pass selects a string and replaces the one before it; a
    // million passes would exhaust a process that released none.
    const auto outcome = RunCapturing(
        "Select",
        "    public static String Name() { return \"Tala\"; }\n"
        "    public static void Main() {\n"
        "        String s = Zero(3) > 0 ? \"a\" : \"b\";\n"
        "        Console.Println(s);\n"
        "        Console.Println(Zero(3) == 0 ? Name() : \"nobody\");\n"
        "        int evens = 0;\n"
        "        for (int i = 0; i < 1000000; i += 1) {\n"
        "            String kind = i % 2 == 0 ? \"even \" + i : \"odd\";\n"
        "            if (kind \\= \"odd\") { evens += 1; }\n"
        "        }\n"
        "        Console.Println(evens);\n"
        "    }\n");
    CHECK(outcome.status == 0);
    CHECK(outcome.output == Lines("b\r\nTala\r\n500000\r\n"));
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable yields strings from match, if and loops")
{
    // The loop replaces the string of the pass before; a million passes
    // would exhaust a process that released none.
    const auto outcome = RunCapturing(
        "Yield",
        "    public static void Main() {\n"
        "        String kind = match (Zero(3)) { 0 -> \"zero\","
        " _ -> \"other\" };\n"
        "        String sign = if (Zero(3) > 0) { \"pos\" }"
        " else { \"not \" + kind };\n"
        "        int i = 0;\n"
        "        String found = while (true) { i += 1;"
        " if (i > 2) { break \"at \" + i; } };\n"
        "        Console.Println(kind + \"|\" + sign + \"|\" + found);\n"
        "        int threes = 0;\n"
        "        for (int n = 0; n < 1000000; n += 1) {\n"
        "            String word = match (n % 3) { 0 -> \"three \" + n,"
        " 1 -> \"one\", _ -> \"two\" };\n"
        "            if (word \\= \"one\" && word \\= \"two\")"
        " { threes += 1; }\n"
        "        }\n"
        "        Console.Println(threes);\n"
        "    }\n");
    CHECK(outcome.status == 0);
    CHECK(outcome.output == Lines("zero|not zero|at 3\r\n333334\r\n"));
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable matches strings by the characters they hold")
{
    // No subject here is the object of the literal it is compared with:
    // each is made at run time. A comparison of objects would select the
    // last arm every time.
    const auto outcome = RunCapturing(
        "Subjects",
        "    public static String Word(_ int n) {\n"
        "        return match (n % 3) { 0 -> \"zero\", 1 -> \"one\","
        " _ -> \"two\" } + \"\";\n"
        "    }\n"
        "    public static void Main() {\n"
        "        Console.Println(match (Word(1)) { \"zero\" -> 0,"
        " \"one\" -> 1, _ -> 9 });\n"
        "        Console.Println(Word(0) is \"zero\");\n"
        "        Console.Println(Word(0) is not \"zero\");\n"
        "        Console.Println(Word(2) is \"zero\" or \"two\");\n"
        "        int total = 0;\n"
        "        for (int n = 0; n < 300000; n += 1) {\n"
        "            total += match (Word(n)) { \"zero\" -> 1,"
        " \"one\" -> 10, String other if other is \"two\" -> 100,"
        " _ -> 100000 };\n"
        "        }\n"
        "        Console.Println(total);\n"
        "    }\n");
    CHECK(outcome.status == 0);
    CHECK(outcome.output
          == Lines("1\r\ntrue\r\nfalse\r\ntrue\r\n11100000\r\n"));
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable names methods through the namespace and the type")
{
    const auto outcome = RunCapturing(
        "Qualified",
        "    public static int Log(_ int v) { Console.Println(v);"
        " return v; }\n"
        "    public static int Run(_ (int) -> int f) { return f(3); }\n"
        "    public static void Main() {\n"
        "        Check(Demo.Program.Pick(1, 4), 4);\n"
        "        int first = Demo.Program.Log(1);\n"
        "        int second = Run(Program::Log);\n"
        "        auto held = Demo.Program::Log;\n"
        "        int third = held(5);\n"
        "        Console.Println(9);\n"
        "    }\n");
    CHECK(outcome.status == 0);
    CHECK(outcome.output == Lines("1\r\n3\r\n5\r\n9\r\n"));
    std::filesystem::remove_all(Directory());
}

TEST_CASE("an executable writes many lines")
{
    const auto outcome
        = RunCapturing("Loop",
                       "    public static void Main() {\n"
                       "        for (int i = 0; i < 20000; i += 1) {\n"
                       "            Console.Printfn(\"line %d\", i);\n"
                       "        }\n"
                       "    }\n");
    CHECK(outcome.status == 0);
    std::string expected;
    for (int index = 0; index < 20000; ++index)
        expected += "line " + std::to_string(index) + Lines("\r\n");
    CHECK(outcome.output == expected);
    std::filesystem::remove_all(Directory());
}
