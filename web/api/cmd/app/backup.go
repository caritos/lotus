package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"time"

	"app/internal/backup"
	"app/internal/config"
	"app/internal/db"
)

func init() {
	commands["backup"] = backupCmd
	commands["verify-backup"] = verifyBackupCmd
}

const backupUsage = "usage: app backup [--keep N] [--label NAME]"

// backupCmd writes a backup set and prints its directory. Without --label it is
// the daily set <timestamp>, pruned to the newest N daily sets; with --label it
// is <timestamp>-<label>, pruned to the newest N sets with that label.
func backupCmd(args []string, getenv func(string) string, stdout io.Writer) error {
	fs := flag.NewFlagSet("backup", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	keep := fs.Int("keep", 14, "number of backup sets to keep (per label)")
	label := fs.String("label", "", "name the set <timestamp>-<label> and prune only sets with this label")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%s: %w", backupUsage, err)
	}
	if fs.NArg() != 0 {
		return errors.New(backupUsage)
	}
	labelSet := false
	fs.Visit(func(f *flag.Flag) { labelSet = labelSet || f.Name == "label" })
	if labelSet && *label == "" {
		return fmt.Errorf("%s: --label must not be empty", backupUsage)
	}
	cfg, err := config.Load(getenv)
	if err != nil {
		return err
	}
	d, err := db.Open(cfg.DBPath())
	if err != nil {
		return err
	}
	defer d.Close()
	res, err := backup.RunLabel(context.Background(), d, cfg.DataDir, *label, *keep, time.Now())
	if err != nil {
		return err
	}
	fmt.Fprintln(stdout, res.Dir)
	return nil
}

// verifyBackupCmd checks a backup set and prints ok, or fails listing problems.
func verifyBackupCmd(args []string, _ func(string) string, stdout io.Writer) error {
	if len(args) != 1 {
		return errors.New("usage: app verify-backup <backup-dir>")
	}
	if err := backup.Verify(args[0]); err != nil {
		return err
	}
	fmt.Fprintln(stdout, "ok")
	return nil
}
