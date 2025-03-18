// package main;

/*
 * @author Archer Heffern
 * @author Danish Abbasi
 * @java-version >=15.0.0
*/

import java.io.ByteArrayOutputStream;
import java.io.FileWriter;
import java.io.IOException;
import java.io.PrintStream;
import java.util.ArrayList;
import java.util.List;

public class Test {
	    public static void main(String[] args) {
        if ((args.length == 2 && args[1].trim().equals("-h"))
        || args.length > 2) {
            System.out.println("Usage [-h|results_destfile]");
            System.exit(0);
        }

        List<TestResult> results = new ArrayList<>();

        results.add(runTest("Testcase 1", Test::test));

        if (args.length == 2) {
            String json = convertResultsToJson(results, true);
            writeToFile(json, args[1]);
        }
        else {
            String json = convertResultsToJson(results, false);
            System.out.println(json);
        }
    }


    public static void test() throws Exception {
        System.out.println("Hello world");

        String expected = """
        Hello world
        """;

        String actual = readStdout();
        String[] actual_lines = cleanString(actual);
        String[] expected_lines = cleanString(expected);
        assertEqualArrays(actual_lines, expected_lines);
    }


    // ================================================
    // UTILITIES: Don't Touch!
    // ================================================
    private static ByteArrayOutputStream stdout_stream = null;
    private static ByteArrayOutputStream stderr_stream = null;
    private static PrintStream previous_stdout = null;
    private static PrintStream previous_stderr = null;

    private static String[] cleanString(String target) {
        String target_lines[] = target.split("\\R+");
        for (int i = 0; i < target_lines.length; i++) {
            target_lines[i] = target_lines[i].trim();
        }
        return target_lines;
    }

    @SuppressWarnings("unused")
    private static String[] agressiveCleanString(String target) {
        String target_lines[] = target.split("\\R+");
        for (int i = 0; i < target_lines.length; i++) {
            String clean_line = target_lines[i].toLowerCase().trim();
            if (clean_line.length() > 0) {
                char last_character = clean_line.charAt(clean_line.length() - 1);
                if (isLineEndingWithPunctuation(last_character)) {
                    clean_line = clean_line.substring(0, clean_line.length()-1).trim();
                }
            }
            target_lines[i] = clean_line;
        }
        return target_lines;
    }

    private static void assertEqualArrays(String[] actual_lines, String[] expected_lines) throws Exception {
        int min_length = actual_lines.length < expected_lines.length? actual_lines.length: expected_lines.length;
        for (int i = 0; i < min_length; i++) {
            if (!actual_lines[i].equals(expected_lines[i])) {
                throw new Exception("Expected \'" + expected_lines[i] + "\' on line " + (i+1) + " but found \'" + actual_lines[i] + "\'.");
            }
        }
        if (actual_lines.length > expected_lines.length) {
            String extra_lines = "Actual output contains extra lines:\n\"\"\"\n";
            for (int i = min_length; i < actual_lines.length; i++) {
                extra_lines += actual_lines[i] + "\n";
            }
            extra_lines += "\"\"\"";
            throw new Exception(extra_lines);
        } else if (actual_lines.length < expected_lines.length) {
            String missing_lines = "Actual output missing lines: \n\"\"\"\n";
            for (int i = min_length; i < expected_lines.length; i++) {
                missing_lines += expected_lines[i] + "\n";
            }
            missing_lines += "\"\"\"";
            throw new Exception(missing_lines);

        }
    }

    @SuppressWarnings("unused")
    public static void println(String s) {
        previous_stdout.println(s);
    }

    @SuppressWarnings("unused")
    public static void eprintln(String s) {
        previous_stderr.println(s);
    }

    @SuppressWarnings("unused")
    private static String readStdout() {
        String contents = stdout_stream.toString();
        stdout_stream.reset();
        return contents;
    }

    @SuppressWarnings("unused")
    private static String readStderr() {
        String contents = stderr_stream.toString();
        stderr_stream.reset();
        return contents;
    }

    @SuppressWarnings("unused")
    private static <E extends Exception> TestResult runTest(String testName, ThrowingFunction<E> testMethod) {
        previous_stdout = System.out;
        previous_stderr = System.err;
        stdout_stream = new ByteArrayOutputStream(); 
        stderr_stream = new ByteArrayOutputStream(); 
        PrintStream new_stdout = new PrintStream(stdout_stream);
        PrintStream new_stderr = new PrintStream(stderr_stream);
        System.setOut(new_stdout);
        System.setErr(new_stderr);
    try {
        testMethod.apply();
        return new TestResult(testName, true, "");
    } catch (Exception e) {
        String errorMessage = e.getClass().getName() + ": " + e.getMessage();
        String detailedError = errorMessage + "\n" + getStackTrace(e);
        return new TestResult(testName, false, detailedError);
    } finally {
        System.setOut(previous_stdout);
        System.setErr(previous_stderr);
    }
}

    private static String getStackTrace(Throwable t) {
        StringBuilder sb = new StringBuilder();
        for (StackTraceElement ste : t.getStackTrace()) {
            sb.append(ste.toString()).append("\n");
        }
        return sb.toString();
    }

    @SuppressWarnings("CallToPrintStackTrace")
    private static void writeToFile(String s, String fileName) {
        try (FileWriter writer = new FileWriter(fileName)) {
            writer.write(s);
            System.out.println("Test results written to " + fileName);
        } catch (IOException e) {
            e.printStackTrace();
        }
    }

     private static String convertResultsToJson(List<TestResult> results, boolean escape) {
        StringBuilder json = new StringBuilder();
        json.append("[\n");
        for (int i = 0; i < results.size(); i++) {
            TestResult result = results.get(i);
            if (escape) {
                result.name = escapeJson(result.name);
                result.reason = escapeJson(result.reason);
            }
            json.append("    {\n");
            json.append("        \"name\": \"").append(result.name).append("\",\n");
            json.append("        \"pass\": ").append(result.pass).append(",\n");
            json.append("        \"reason\": \"").append(result.reason).append("\"\n");
            json.append("    }");

            if (i < results.size() - 1) {
                json.append(",");
            }
            json.append("\n");
        }
        json.append("]\n");
        return json.toString();
    }

     private static String escapeJson(String s) {
        if (s == null) {
            return "";
        }
        return s.replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\n", "\\n")
                .replace("\r", "\\r");
    }

    private static boolean isLineEndingWithPunctuation(char c) {
        return c == '.' || c == '!' || c == '?';
    }

    @FunctionalInterface
    interface ThrowingFunction<E extends Exception> {
        void apply() throws E;
    }

    static class TestResult{
        String name; 
        boolean pass; 
        String reason; 

        TestResult(String name, boolean pass, String reason){
            this.name  = name;
            this.pass = pass; 
            this.reason = reason; 
        }
    }
}
