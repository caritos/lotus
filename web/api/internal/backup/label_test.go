package backup

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"app/internal/testutil"
)

func TestLabeledSetIsNamedStampDashLabel(t *testing.T) {
	d := testutil.NewDB(t)
	seedNote(t, d, "n1", nil)
	dataDir := t.TempDir()
	res, err := RunLabel(context.Background(), d, dataDir, "predeploy", 5, t0)
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(dataDir, "backups", "20261027T120000Z-predeploy"); res.Dir != want {
		t.Fatalf("Dir = %q, want %q", res.Dir, want)
	}
	if err := Verify(res.Dir); err != nil {
		t.Fatalf("Verify labeled set: %v", err)
	}
	checkPerm := func(p string, want os.FileMode) {
		t.Helper()
		fi, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		if fi.Mode().Perm() != want {
			t.Errorf("%s mode = %o, want %o", p, fi.Mode().Perm(), want)
		}
	}
	checkPerm(res.Dir, 0o700)
	checkPerm(filepath.Join(res.Dir, "app.db"), 0o600)
}

func TestLabeledPruneNeverTouchesDailySets(t *testing.T) {
	d := testutil.NewDB(t)
	dataDir := t.TempDir()
	b := filepath.Join(dataDir, "backups")
	for i := 0; i < 3; i++ {
		if _, err := Run(context.Background(), d, dataDir, 14, t0.Add(time.Duration(i)*time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := RunLabel(context.Background(), d, dataDir, "other", 5, t0.Add(30*time.Minute)); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 4; i++ {
		if _, err := RunLabel(context.Background(), d, dataDir, "predeploy", 2, t0.Add(time.Duration(10+i)*time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	got := strings.Join(names(t, b), ",")
	want := "20261027T120000Z,20261027T123000Z-other,20261027T130000Z,20261027T140000Z," +
		"20261028T000000Z-predeploy,20261028T010000Z-predeploy"
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
}

func TestDailyPruneNeverTouchesLabeledSets(t *testing.T) {
	d := testutil.NewDB(t)
	dataDir := t.TempDir()
	b := filepath.Join(dataDir, "backups")
	for i := 0; i < 3; i++ {
		if _, err := RunLabel(context.Background(), d, dataDir, "predeploy", 5, t0.Add(time.Duration(i)*time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 3; i++ {
		if _, err := Run(context.Background(), d, dataDir, 1, t0.Add(time.Duration(10+i)*time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	got := strings.Join(names(t, b), ",")
	want := "20261027T120000Z-predeploy,20261027T130000Z-predeploy,20261027T140000Z-predeploy,20261028T000000Z"
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
}

func TestRunLabelRejectsInvalidLabels(t *testing.T) {
	d := testutil.NewDB(t)
	for _, label := range []string{"Predeploy", "1st", "-x", "a_b", "a.b", "a/b", "a b", "../x", "abcdefghijklmnopq", "pré"} {
		dataDir := t.TempDir()
		_, err := RunLabel(context.Background(), d, dataDir, label, 5, t0)
		if err == nil || !strings.Contains(err.Error(), "label") {
			t.Errorf("label %q: err = %v, want a label error", label, err)
		}
		if _, err := os.Stat(filepath.Join(dataDir, "backups")); err == nil {
			t.Errorf("label %q: backups dir created despite the error", label)
		}
	}
	for _, label := range []string{"a", "predeploy", "pre-deploy-2", "abcdefghijklmnop"} {
		if _, err := RunLabel(context.Background(), d, t.TempDir(), label, 5, t0); err != nil {
			t.Errorf("label %q: %v", label, err)
		}
	}
}

func TestSameSecondDifferentLabelsDoNotCollide(t *testing.T) {
	d := testutil.NewDB(t)
	seedNote(t, d, "n1", nil)
	dataDir := t.TempDir()
	daily, err := Run(context.Background(), d, dataDir, 14, t0)
	if err != nil {
		t.Fatal(err)
	}
	pre, err := RunLabel(context.Background(), d, dataDir, "predeploy", 5, t0)
	if err != nil {
		t.Fatalf("labeled run in the same second as the daily run: %v", err)
	}
	if _, err := RunLabel(context.Background(), d, dataDir, "predeploy", 5, t0); err == nil {
		t.Fatal("same label, same second: want an error")
	}
	for _, dir := range []string{daily.Dir, pre.Dir} {
		if err := Verify(dir); err != nil {
			t.Fatalf("Verify %s: %v", dir, err)
		}
	}
}

func TestStaleLabeledPartialRemoved(t *testing.T) {
	d := testutil.NewDB(t)
	dataDir := t.TempDir()
	b := filepath.Join(dataDir, "backups")
	writeFile(t, filepath.Join(b, "20261027T110000Z-predeploy.partial", "app.db"), "junk")
	writeFile(t, filepath.Join(b, "20261027T130000Z-predeploy.partial", "app.db"), "future")
	if _, err := Run(context.Background(), d, dataDir, 5, t0); err != nil {
		t.Fatal(err)
	}
	got := strings.Join(names(t, b), ",")
	if want := "20261027T120000Z,20261027T130000Z-predeploy.partial"; got != want {
		t.Fatalf("got %s, want %s", got, want)
	}
}
