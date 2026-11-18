// Running other programs, for System.Process. A program gets this part of
// the runtime only if it uses one of its functions; see runtime.go.
package main

import (
	rt_bytes "bytes"
	rt_fmt "fmt"
	rt_exec "os/exec"
	rt_strings "strings"
)

// --- runtime ---

// Runs a program with its arguments, giving it input on its standard input,
// and gives what it printed on its standard output. A program that cannot be
// started, or that ends with a status other than 0, is an error, with what
// it printed on its standard error.
func rt_readProcess(name string, args List[string], input string) (string, error) {
	var as []string
	for l := args; l != nil; l = l.F1.force() {
		as = append(as, l.F0)
	}
	cmd := rt_exec.Command(name, as...)
	cmd.Stdin = rt_strings.NewReader(input)
	var stderr rt_bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		if msg := rt_strings.TrimSpace(stderr.String()); msg != "" {
			return "", rt_fmt.Errorf("%s: %v: %s", name, err, msg)
		}
		return "", rt_fmt.Errorf("%s: %v", name, err)
	}
	return string(out), nil
}
