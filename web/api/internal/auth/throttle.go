package auth

import (
	"container/list"
	"net/netip"
	"sync"
	"time"
)

const (
	throttleWindow     = 15 * time.Minute
	pairLimit          = 5
	emailLimit         = 20
	ipLimit            = 50
	maxThrottleEntries = 10000
)

// counter is a bounded fixed-window failure counter. Entries are kept in
// creation order, which is also expiry order, so eviction and expiry are O(1).
type counter struct {
	limit int
	m     map[string]*list.Element
	order *list.List
}

type entry struct {
	key   string
	count int
	start time.Time
}

func newCounter(limit int) *counter {
	return &counter{limit: limit, m: map[string]*list.Element{}, order: list.New()}
}

func (c *counter) expire(now time.Time) {
	for e := c.order.Front(); e != nil; e = c.order.Front() {
		if now.Sub(e.Value.(*entry).start) < throttleWindow {
			return
		}
		c.remove(e)
	}
}

func (c *counter) remove(e *list.Element) {
	delete(c.m, e.Value.(*entry).key)
	c.order.Remove(e)
}

// blockedFor returns how long key stays blocked, or 0 if it is not.
func (c *counter) blockedFor(key string, now time.Time) time.Duration {
	c.expire(now)
	if e, ok := c.m[key]; ok {
		en := e.Value.(*entry)
		if en.count >= c.limit {
			return en.start.Add(throttleWindow).Sub(now)
		}
	}
	return 0
}

// undo gives back one counted attempt, dropping the entry at zero.
func (c *counter) undo(key string) {
	e, ok := c.m[key]
	if !ok {
		return
	}
	en := e.Value.(*entry)
	if en.count--; en.count <= 0 {
		c.remove(e)
	}
}

func (c *counter) add(key string, now time.Time) {
	c.expire(now)
	if e, ok := c.m[key]; ok {
		e.Value.(*entry).count++
		return
	}
	for c.order.Len() >= maxThrottleEntries {
		c.remove(c.order.Front())
	}
	c.m[key] = c.order.PushBack(&entry{key: key, count: 1, start: now})
}

// throttle limits failed logins per (email, ip), per email and per ip.
type throttle struct {
	mu    sync.Mutex
	now   func() time.Time
	pair  *counter
	email *counter
	ip    *counter
}

func newThrottle(now func() time.Time) *throttle {
	return &throttle{now: now, pair: newCounter(pairLimit), email: newCounter(emailLimit), ip: newCounter(ipLimit)}
}

// ipKey groups IPv6 addresses by /64 so one host cannot rotate through its prefix.
func ipKey(ip string) string {
	a, err := netip.ParseAddr(ip)
	if err != nil {
		return ip
	}
	a = a.Unmap()
	if a.Is6() {
		p, err := a.Prefix(64)
		if err == nil {
			return p.Masked().String()
		}
	}
	return a.String()
}

// attempt atomically checks all three counters and, when the attempt is
// allowed, records it in each. Doing both in one critical section (before the
// slow bcrypt compare) stops parallel requests from all passing the check. It
// returns the retry delay and false when the attempt must be refused; refused
// attempts are not counted.
func (t *throttle) attempt(email, ip string) (time.Duration, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	ip = ipKey(ip)
	pk := email + "\x00" + ip
	var worst time.Duration
	for _, d := range []time.Duration{
		t.pair.blockedFor(pk, now),
		t.email.blockedFor(email, now),
		t.ip.blockedFor(ip, now),
	} {
		worst = max(worst, d)
	}
	if worst > 0 {
		return worst, false
	}
	t.pair.add(pk, now)
	t.email.add(email, now)
	t.ip.add(ip, now)
	return 0, true
}

// success undoes the attempt after a correct password: the (email, ip) counter
// is cleared, while the per-email and per-ip counters only give back this one
// attempt, so a success can never reset failures made by anyone else.
func (t *throttle) success(email, ip string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	ip = ipKey(ip)
	if e, ok := t.pair.m[email+"\x00"+ip]; ok {
		t.pair.remove(e)
	}
	t.email.undo(email)
	t.ip.undo(ip)
}

// size is the total number of tracked entries (for tests).
func (t *throttle) size() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.pair.expire(t.now())
	t.email.expire(t.now())
	t.ip.expire(t.now())
	return t.pair.order.Len() + t.email.order.Len() + t.ip.order.Len()
}
