package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"time"

	"goweb/internal/backup"
	"goweb/internal/config"
	"goweb/internal/db"
)

func init() {
	commands["backup"] = backupCmd
	commands["verify-backup"] = verifyBackupCmd
}

// backupCmd writes a backup set and prints its directory.
func backupCmd(args []string, getenv func(string) string, stdout io.Writer) error {
	fs := flag.NewFlagSet("backup", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	keep := fs.Int("keep", 14, "number of backup sets to keep")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("usage: goweb backup [--keep N]: %w", err)
	}
	if fs.NArg() != 0 {
		return errors.New("usage: goweb backup [--keep N]")
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
	res, err := backup.Run(context.Background(), d, cfg.DataDir, *keep, time.Now())
	if err != nil {
		return err
	}
	fmt.Fprintln(stdout, res.Dir)
	return nil
}

// verifyBackupCmd checks a backup set and prints ok, or fails listing problems.
func verifyBackupCmd(args []string, _ func(string) string, stdout io.Writer) error {
	if len(args) != 1 {
		return errors.New("usage: goweb verify-backup <backup-dir>")
	}
	if err := backup.Verify(args[0]); err != nil {
		return err
	}
	fmt.Fprintln(stdout, "ok")
	return nil
}
