// SPDX-FileCopyrightText: 2026 APS Conecta
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"flag"
	"fmt"
	"os"
)

func init() {
	if secret := os.Getenv("IMAGINARY_SECRET"); secret != "" {
		if err := flag.Set("key", secret); err != nil {
			fmt.Fprintln(os.Stderr, "Imaginary API key could not be configured.")
			os.Exit(1)
		}
	}
}
