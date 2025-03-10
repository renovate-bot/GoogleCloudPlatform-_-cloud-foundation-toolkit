package cmd

import (
	"bytes"
	"strings"
	"testing"

	"github.com/spf13/cobra"
)

func ExecuteCommand(root *cobra.Command, args ...string) (output string, err error) {
	_, output, err = ExecuteCommandC(root, args...)
	return output, err
}

func ExecuteCommandC(root *cobra.Command, args ...string) (c *cobra.Command, output string, err error) {
	buf := new(bytes.Buffer)
	setOutput(root, buf)

	// reset command state after prev test execution
	root.SetArgs([]string{})
	root.ResetFlags()

	// set child command and/or command line args
	if args != nil {
		root.SetArgs(args)
	}

	c, err = root.ExecuteC()

	return c, buf.String(), err
}

func setOutput(rootCommand *cobra.Command, buf *bytes.Buffer) {
	rootCommand.SetErr(buf)
	rootCommand.SetOut(buf)
	for _, command := range rootCommand.Commands() {
		setOutput(command, buf)
	}
}

func TestRootCommand(t *testing.T) {
	rootCmd.SetArgs([]string{})
	output, err := ExecuteCommand(rootCmd)
	if !strings.Contains(output, "Google Cloud Foundation Toolkit CLI") {
		t.Errorf("expected help output, got: %s", output)
	}
	if err != nil {
		t.Errorf("expected no error, got: %v", err)
	}
}

func TestRootCommandHelpArgs(t *testing.T) {
	output, err := ExecuteCommand(rootCmd, "-h")
	if output == "" {
		t.Errorf("expected no output, got: %s", output)
	}
	if err != nil {
		t.Errorf("expected no error, got: %v", err)
	}
}

func TestRootCommandWithUnknownCommand(t *testing.T) {
	output, err := ExecuteCommand(rootCmd, "unknown")
	prefix := "Error: unknown command \"unknown\" for \"cft\""
	if !strings.HasPrefix(output, prefix) {
		t.Errorf("expected to have prefix: %s, actual: %s", prefix, output)
	}
	if err == nil {
		t.Errorf("expected to have error but it nil")
	}
}
