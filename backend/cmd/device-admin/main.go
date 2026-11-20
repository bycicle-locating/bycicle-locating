// Command device-admin 登记可绑定的车载设备。
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/bycicle-locating/backend/internal/provision"
	"github.com/bycicle-locating/backend/internal/store"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Stdout); err != nil && !errors.Is(err, flag.ErrHelp) {
		slog.Error("设备登记失败", "err", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, out io.Writer) error {
	flags := flag.NewFlagSet("bkl-device-admin", flag.ContinueOnError)
	id := flags.String("id", "", "设备编号 BKL-YYYY-NNNNNN")
	model := flags.String("model", "BKL1", "设备型号")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *id == "" || flags.NArg() != 0 {
		return fmt.Errorf("device-admin: 请通过 -id 指定设备编号")
	}
	dsn := strings.TrimSpace(os.Getenv("DATABASE_URL"))
	if dsn == "" {
		return fmt.Errorf("device-admin: 必须设置 DATABASE_URL")
	}

	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	db, err := store.NewPostgres(ctx, dsn)
	if err != nil {
		return err
	}
	defer db.Close()
	if err := db.CheckSchema(ctx); err != nil {
		return err
	}
	code, err := provision.CreateDevice(ctx, db, os.Getenv("CLAIM_PEPPER"), *id, *model)
	if err != nil {
		return err
	}
	if _, err := fmt.Fprintf(out, "deviceId=%s claimCode=%s\n", *id, code); err != nil {
		return fmt.Errorf("device-admin: 设备已登记，输出声明码失败: %w", err)
	}
	return nil
}
