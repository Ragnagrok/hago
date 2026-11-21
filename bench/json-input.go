// Writes the JSON the README's JSON benchmark parses, always the same: 3.7 MB
// of records such as a web API gives, with strings (some with escapes and
// characters outside ASCII), integers, fractions, booleans, nulls, and
// nested arrays and objects, indented by two as jq prints them.
//
//	go run bench/json-input.go > /tmp/bench.json
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
)

var words = []string{
	"strict", "lazy", "thunk", "monad", "functor", "parser", "pretty", "printer",
	"goroutine", "channel", "vector", "iterator", "record", "newtype", "class",
	"instance", "module", "export", "import", "type", "kind", "café", "naïve",
	"日本", "señal", "Ωmega", "tab\there", "quote\"d", "back\\slash", "line\nbreak",
}

func sentence(r *rand.Rand, n int) string {
	s := ""
	for i := 0; i < n; i++ {
		if i > 0 {
			s += " "
		}
		s += words[r.IntN(len(words))]
	}
	return s
}

// One record, an ordered list of fields so the output is always the same.
type field struct {
	key   string
	value any
}

type object []field

func (o object) MarshalJSON() ([]byte, error) {
	b := []byte{'{'}
	for i, f := range o {
		if i > 0 {
			b = append(b, ',')
		}
		k, _ := json.Marshal(f.key)
		v, err := json.Marshal(f.value)
		if err != nil {
			return nil, err
		}
		b = append(append(append(b, k...), ':'), v...)
	}
	return append(b, '}'), nil
}

func record(r *rand.Rand, id int) object {
	tags := []any{}
	for i := r.IntN(5); i > 0; i-- {
		tags = append(tags, words[r.IntN(len(words))])
	}
	scores := []any{}
	for i := r.IntN(6); i > 0; i-- {
		scores = append(scores, float64(r.IntN(100000))/100)
	}
	var manager any
	if r.IntN(3) > 0 {
		manager = r.IntN(id + 1)
	}
	return object{
		{"id", id},
		{"name", sentence(r, 2)},
		{"email", fmt.Sprintf("user%d@example.com", id)},
		{"active", r.IntN(2) == 0},
		{"balance", float64(r.IntN(10000000))/100 - 20000},
		{"ratio", r.Float64()},
		{"big", float64(r.IntN(1000)) * 1e20},
		{"manager", manager},
		{"tags", tags},
		{"scores", scores},
		{"address", object{
			{"street", sentence(r, 3)},
			{"number", r.IntN(5000)},
			{"location", []any{r.Float64()*180 - 90, r.Float64()*360 - 180}},
		}},
		{"notes", sentence(r, 1+r.IntN(12))},
		{"history", []any{}},
		{"extra", object{}},
	}
}

func main() {
	r := rand.New(rand.NewPCG(1, 2))
	var records []any
	for id := 0; id < 5700; id++ {
		records = append(records, record(r, id))
	}
	out, err := json.MarshalIndent(object{{"version", 3}, {"records", records}}, "", "  ")
	if err != nil {
		panic(err)
	}
	w := bufio.NewWriter(os.Stdout)
	w.Write(out)
	w.WriteString("\n")
	w.Flush()
}
