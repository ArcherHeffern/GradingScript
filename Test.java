
package main;
import java.io.File;
import java.io.IOException;

public class Test {
	public static void main(String[] args) throws IOException {
		if (args.length != 2) {
			System.out.println("Usage [destfile]");
			System.exit(1);
		}

		runTests();

		if (!new File(args[1]).createNewFile()) {
			throw new IOException();	
		}
	}

	private static void runTests() {
		System.out.println("Hello world");
		// PCB.PrintHello();
	}
}
