package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"goweb/internal/auth"
	"goweb/internal/config"
	"goweb/internal/db"
)

// stdin is where `user create` reads the password; tests replace it.
var stdin io.Reader = os.Stdin

func init() { commands["user"] = userCmd }

const userUsage = "usage: goweb user create <email>   (password on the first line of stdin)"

func userCmd(args []string, getenv func(string) string, stdout io.Writer) error {
	if len(args) != 2 || args[0] != "create" {
		return errors.New(userUsage)
	}
	cfg, err := config.Load(getenv)
	if err != nil {
		return err
	}
	line, err := bufio.NewReader(stdin).ReadString('\n')
	if err != nil && !(errors.Is(err, io.EOF) && line != "") {
		return errors.New("password: expected the password on the first line of stdin")
	}
	password := strings.TrimRight(line, "\r\n")

	ctx := context.Background()
	d, err := db.Open(cfg.DBPath())
	if err != nil {
		return err
	}
	defer d.Close()
	if err := db.Migrate(ctx, d); err != nil {
		return err
	}
	u, err := auth.NewService(d, cfg, time.Now).CreateUser(ctx, args[1], password)
	switch {
	case errors.Is(err, auth.ErrEmailTaken):
		return fmt.Errorf("user %s already exists", strings.ToLower(strings.TrimSpace(args[1])))
	case errors.Is(err, auth.ErrInvalidEmail):
		return errors.New("invalid email: must contain @")
	case errors.Is(err, auth.ErrWeakPassword):
		return errors.New("password must be 8 to 72 bytes")
	case err != nil:
		return err
	}
	fmt.Fprintf(stdout, "created %s\n", u.Email)
	return nil
}
