// tomljson validates TOML read from stdin and prints it as JSON (used by the rspec template tests).
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"

	"github.com/BurntSushi/toml"
)

func main() {
	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	var doc map[string]any
	if _, err := toml.Decode(string(input), &doc); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := json.NewEncoder(os.Stdout).Encode(doc); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}
