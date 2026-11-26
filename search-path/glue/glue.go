package glue

import "strings"

// Twice is the Go package of the module that search-path/Main.hgo uses.
func Twice(s string) string { return strings.Repeat(s, 2) }
