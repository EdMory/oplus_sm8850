#!/bin/bash
# TCP Brutal 1.0.2 → 2.0.1 升级脚本
# 用法：在 kernel_workspace/common 目录下执行
# bash tcp-brutal-upgrade.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_DIR="$(pwd)"

echo "[1/5] 覆写 net/ipv4/tcp_brutal.c（占位符，实现移入子目录）..."
cat > net/ipv4/tcp_brutal.c << 'PLACEHOLDER_EOF'
/* TCP Brutal v2.0.1 — implementation moved to net/ipv4/tcp_brutal/ */
PLACEHOLDER_EOF

echo "[2/5] 创建 net/ipv4/tcp_brutal/ 目录..."
mkdir -p net/ipv4/tcp_brutal

echo "[3/5] 写入 brutal.h ..."
cat > net/ipv4/tcp_brutal/brutal.h << 'EOF'
#ifndef BRUTAL_H
#define BRUTAL_H

#include <linux/version.h>
#include <linux/refcount.h>
#include <linux/spinlock.h>
#include <net/tcp.h>

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
#error "TCP Brutal requires Linux 5.10 or later"
#endif

#define BRUTAL_VERSION_MAJOR 2
#define BRUTAL_VERSION_MINOR 0
#define BRUTAL_VERSION_PATCH 1
#define BRUTAL_VERSION ((BRUTAL_VERSION_MAJOR << 16) | (BRUTAL_VERSION_MINOR << 8) | BRUTAL_VERSION_PATCH)

#define TCP_BRUTAL_PARAMS 23301  /* setsockopt/getsockopt: struct brutal_params */
#define TCP_BRUTAL_VERSION 23302 /* getsockopt: u32 (major << 16 | minor << 8 | patch) */

#define INIT_PACING_RATE 125000 /* 1 Mbps */
#define INIT_CWND_GAIN 20

#define MIN_PACING_RATE 62500           /* 500 Kbps */
#define MAX_PACING_RATE 125000000000ULL /* 1 Tbps */
#define MIN_CWND_GAIN 5
#define MAX_CWND_GAIN 80
#define MIN_CWND 4

#define PKT_INFO_SLOTS 4

struct brutal_pkt_info
{
	u32 sec;
	u32 acked;
	u32 losses;
};

struct brutal_group
{
	struct hlist_node node;
	refcount_t refcnt;
	spinlock_t lock;
	u64 id;
	kuid_t uid;
	struct net *net;

	u64 rate;
	u32 cwnd_gain;
	u8 locked;
	u32 members;
	u64 sent_bytes;
	u64 next_ns;
};

struct brutal
{
	u64 rate;
	u32 cwnd_gain;
	u32 ack_rate;
	struct brutal_group *group;

	u64 resv_start_ns;
	u64 resv_bytes;
	u64 resv_bytes_sent;

	struct brutal_pkt_info slots[PKT_INFO_SLOTS];
};

struct brutal_params
{
	u64 rate;
	u32 cwnd_gain;
	u64 group_id;
} __packed;

#define BRUTAL_PARAMS_V1_SIZE offsetof(struct brutal_params, group_id)

extern struct tcp_congestion_ops tcp_brutal_ops;
void brutal_update_rate(struct sock *sk);

struct brutal_group *brutal_group_alloc(u64 id);
void brutal_group_put(struct brutal_group *g);
void brutal_group_join(struct brutal *brutal, struct brutal_group *g);
void brutal_group_leave(struct brutal *brutal);
void brutal_sockopt_init(void);
void brutal_sockopt_install(struct sock *sk);
void brutal_sockopt_uninstall(struct sock *sk);

void brutal_apply_rule(struct sock *sk, struct brutal *brutal);
int brutal_rules_init(void);
void brutal_rules_exit(void);

#endif /* BRUTAL_H */
EOF

echo "[4/5] 写入 brutal_cc.c ..."
cat > net/ipv4/tcp_brutal/brutal_cc.c << 'EOF'
/* TCP Brutal v2.0.1 — congestion control core */
#include <linux/module.h>
#include <linux/math64.h>
#include "brutal.h"

#define MIN_PKT_INFO_SAMPLES 50
#define MIN_ACK_RATE_PERCENT 80

#define RESV_STALE_NS (20 * NSEC_PER_MSEC)
#define GROUP_MAX_LAG_NS (2 * NSEC_PER_MSEC)

static u64 brutal_effective_rate(const struct brutal *brutal)
{
	u64 rate = brutal->group ? READ_ONCE(brutal->group->rate) : brutal->rate;

	return div_u64(rate * 100, brutal->ack_rate);
}

void brutal_update_rate(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct brutal *brutal = inet_csk_ca(sk);

	u32 sec = div_u64(tp->tcp_mstamp, USEC_PER_SEC);
	u32 min_sec = sec - PKT_INFO_SLOTS;
	u32 acked = 0, losses = 0;
	u32 ack_rate;
	u64 rate, bdp, cwnd;
	u32 cwnd_gain;

	for (int i = 0; i < PKT_INFO_SLOTS; i++) {
		if (brutal->slots[i].sec >= min_sec) {
			acked += brutal->slots[i].acked;
			losses += brutal->slots[i].losses;
		}
	}
	if (acked + losses < MIN_PKT_INFO_SAMPLES)
		ack_rate = 100;
	else {
		ack_rate = acked * 100 / (acked + losses);
		if (ack_rate < MIN_ACK_RATE_PERCENT)
			ack_rate = MIN_ACK_RATE_PERCENT;
	}
	brutal->ack_rate = ack_rate;

	rate = brutal_effective_rate(brutal);
	cwnd_gain = brutal->group ? READ_ONCE(brutal->group->cwnd_gain) : brutal->cwnd_gain;

	bdp = mul_u64_u64_div_u64(rate, max_t(u32, tp->srtt_us >> 3, USEC_PER_MSEC), USEC_PER_SEC);
	cwnd = div_u64(bdp * cwnd_gain, 10 * tp->mss_cache);

	tp->snd_cwnd = clamp_t(u64, cwnd, MIN_CWND, min_t(u32, tp->snd_cwnd_clamp, INT_MAX));

	WRITE_ONCE(sk->sk_pacing_rate, min_t(u64, rate, READ_ONCE(sk->sk_max_pacing_rate)));
}

static u32 brutal_tso_segs_estimate(const struct sock *sk, u64 rate, u32 mss)
{
	unsigned long bytes = rate >> READ_ONCE(sk->sk_pacing_shift);

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 18, 0)
	u32 r = tcp_min_rtt(tcp_sk(sk)) >> READ_ONCE(sock_net(sk)->ipv4.sysctl_tcp_tso_rtt_log);
	if (r < BITS_PER_TYPE(sk->sk_gso_max_size))
		bytes += sk->sk_gso_max_size >> r;
#endif
	bytes = min_t(unsigned long, bytes, sk->sk_gso_max_size);
	return clamp_t(u32, bytes / mss, 2, sk->sk_gso_max_segs);
}

static u32 brutal_burst_estimate(const struct sock *sk, u64 rate, u32 unsent)
{
	const struct tcp_sock *tp = tcp_sk(sk);
	u32 segs = brutal_tso_segs_estimate(sk, rate, tp->mss_cache);

	segs = min(segs, tp->snd_cwnd - tcp_packets_in_flight(tp));
	unsent = min(unsent, tcp_wnd_end(tp) - tp->snd_nxt);
	return min_t(u32, segs * tp->mss_cache, unsent);
}

static void brutal_group_reserve(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct brutal *brutal = inet_csk_ca(sk);
	struct brutal_group *g = brutal->group;
	u64 now = tp->tcp_clock_cache;
	u64 rate, start;
	u32 unsent, burst;

	if (!g)
		return;

	rate = brutal_effective_rate(brutal);

	if (brutal->resv_bytes) {
		u64 sent = tp->bytes_sent - brutal->resv_bytes_sent;
		s64 delta;

		if (!sent && (s64)(now - brutal->resv_start_ns) < (s64)RESV_STALE_NS) {
			if (tp->tcp_wstamp_ns < brutal->resv_start_ns)
				tp->tcp_wstamp_ns = brutal->resv_start_ns;
			return;
		}
		delta = (s64)sent - (s64)brutal->resv_bytes;
		spin_lock_bh(&g->lock);
		if (delta >= 0)
			g->next_ns += div64_u64((u64)delta * NSEC_PER_SEC, rate);
		else
			g->next_ns -= div64_u64((u64)(-delta) * NSEC_PER_SEC, rate);
		g->sent_bytes += sent;
		spin_unlock_bh(&g->lock);
		brutal->resv_bytes = 0;
	}

	unsent = tp->write_seq - tp->snd_nxt;
	if (!unsent) {
		if (tp->lost_out <= tp->retrans_out)
			return;
		unsent = tp->mss_cache;
	}
	if (tcp_packets_in_flight(tp) >= tp->snd_cwnd || !after(tcp_wnd_end(tp), tp->snd_nxt))
		return;

	burst = brutal_burst_estimate(sk, rate, unsent);

	spin_lock_bh(&g->lock);
	start = max(g->next_ns, now - GROUP_MAX_LAG_NS);
	g->next_ns = start + div64_u64((u64)burst * NSEC_PER_SEC, rate);
	spin_unlock_bh(&g->lock);

	brutal->resv_start_ns = start;
	brutal->resv_bytes = burst;
	brutal->resv_bytes_sent = tp->bytes_sent;
	if (tp->tcp_wstamp_ns < start)
		tp->tcp_wstamp_ns = start;
}

#ifdef BRUTAL_HAVE_TSO_SEGS
static u32 brutal_tso_segs(struct sock *sk, unsigned int mss_now)
{
	brutal_group_reserve(sk);
	return brutal_tso_segs_estimate(sk, READ_ONCE(sk->sk_pacing_rate), mss_now);
}
#else
static u32 brutal_min_tso_segs(struct sock *sk)
{
	brutal_group_reserve(sk);
	return 2;
}
#endif

static void brutal_init(struct sock *sk)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct brutal *brutal = inet_csk_ca(sk);

	brutal_sockopt_install(sk);

	tp->snd_ssthresh = TCP_INFINITE_SSTHRESH;

	memset(brutal, 0, sizeof(*brutal));
	brutal->rate = INIT_PACING_RATE;
	brutal->cwnd_gain = INIT_CWND_GAIN;
	brutal->ack_rate = 100;

	brutal_apply_rule(sk, brutal);
	if (brutal->group)
		brutal_update_rate(sk);

	cmpxchg(&sk->sk_pacing_status, SK_PACING_NONE, SK_PACING_NEEDED);
}

static void brutal_release(struct sock *sk)
{
	brutal_group_leave(inet_csk_ca(sk));
	brutal_sockopt_uninstall(sk);
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 10, 0)
static void brutal_main(struct sock *sk, u32 ack, int flag, const struct rate_sample *rs)
#else
static void brutal_main(struct sock *sk, const struct rate_sample *rs)
#endif
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct brutal *brutal = inet_csk_ca(sk);

	u32 sec, slot;

	if (rs->delivered < 0 || rs->interval_us <= 0)
		return;

	sec = div_u64(tp->tcp_mstamp, USEC_PER_SEC);
	slot = sec % PKT_INFO_SLOTS;

	if (brutal->slots[slot].sec == sec) {
		brutal->slots[slot].acked += rs->acked_sacked;
		brutal->slots[slot].losses += rs->losses;
	} else {
		brutal->slots[slot].sec = sec;
		brutal->slots[slot].acked = rs->acked_sacked;
		brutal->slots[slot].losses = rs->losses;
	}

	brutal_update_rate(sk);
}

static u32 brutal_undo_cwnd(struct sock *sk)
{
	return tcp_sk(sk)->snd_cwnd;
}

static u32 brutal_ssthresh(struct sock *sk)
{
	return tcp_sk(sk)->snd_ssthresh;
}

struct tcp_congestion_ops tcp_brutal_ops = {
	.flags = TCP_CONG_NON_RESTRICTED,
	.name = "brutal",
	.owner = THIS_MODULE,
	.init = brutal_init,
	.release = brutal_release,
	.cong_control = brutal_main,
	.undo_cwnd = brutal_undo_cwnd,
	.ssthresh = brutal_ssthresh,
#ifdef BRUTAL_HAVE_TSO_SEGS
	.tso_segs = brutal_tso_segs,
#else
	.min_tso_segs = brutal_min_tso_segs,
#endif
};

static int __init brutal_register(void)
{
	int ret;

	BUILD_BUG_ON(sizeof(struct brutal) > ICSK_CA_PRIV_SIZE);
	BUILD_BUG_ON(sizeof(struct brutal_params) != 20);

	brutal_sockopt_init();
	ret = brutal_rules_init();
	if (ret)
		return ret;
	ret = tcp_register_congestion_control(&tcp_brutal_ops);
	if (ret)
		brutal_rules_exit();
	return ret;
}

static void __exit brutal_unregister(void)
{
	tcp_unregister_congestion_control(&tcp_brutal_ops);
	brutal_rules_exit();
}

module_init(brutal_register);
module_exit(brutal_unregister);

MODULE_AUTHOR("The Hysteria Project");
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("TCP Brutal");
MODULE_VERSION(__stringify(BRUTAL_VERSION_MAJOR) "." __stringify(BRUTAL_VERSION_MINOR) "." __stringify(BRUTAL_VERSION_PATCH));
EOF

echo "[4/5] 写入 brutal_sockopt.c ..."
cat > net/ipv4/tcp_brutal/brutal_sockopt.c << 'EOF'
/* TCP Brutal v2.0.1 — groups and socket option interface */
#include <linux/hashtable.h>
#include <linux/slab.h>
#include "brutal.h"

#if IS_ENABLED(CONFIG_IPV6)
#include <net/transp_v6.h>
#endif
#if IS_ENABLED(CONFIG_TLS)
#include <net/tls.h>
#endif

static DEFINE_HASHTABLE(brutal_groups, 8);
static DEFINE_SPINLOCK(brutal_groups_lock);

static struct proto tcp_prot_override __ro_after_init;
#ifdef _TRANSP_V6_H
static struct proto tcpv6_prot_override __ro_after_init;
#endif

struct brutal_group *brutal_group_alloc(u64 id)
{
	struct brutal_group *g = kzalloc(sizeof(*g), GFP_KERNEL);

	if (!g)
		return NULL;
	refcount_set(&g->refcnt, 1);
	spin_lock_init(&g->lock);
	g->id = id;
	g->rate = INIT_PACING_RATE;
	g->cwnd_gain = INIT_CWND_GAIN;
	return g;
}

static struct brutal_group *brutal_group_get(struct sock *sk, u64 id)
{
	struct brutal_group *g, *ng = brutal_group_alloc(id);

	spin_lock_bh(&brutal_groups_lock);
	hash_for_each_possible(brutal_groups, g, node, id) {
		if (g->id == id && uid_eq(g->uid, sk->sk_uid) && g->net == sock_net(sk) &&
		    refcount_inc_not_zero(&g->refcnt)) {
			spin_unlock_bh(&brutal_groups_lock);
			kfree(ng);
			return g;
		}
	}
	if (ng) {
		ng->uid = sk->sk_uid;
		ng->net = sock_net(sk);
		hash_add(brutal_groups, &ng->node, id);
	}
	spin_unlock_bh(&brutal_groups_lock);
	return ng;
}

void brutal_group_put(struct brutal_group *g)
{
	if (!refcount_dec_and_test(&g->refcnt))
		return;
	spin_lock_bh(&brutal_groups_lock);
	hash_del(&g->node);
	spin_unlock_bh(&brutal_groups_lock);
	kfree(g);
}

void brutal_group_join(struct brutal *brutal, struct brutal_group *g)
{
	brutal->group = g;
	spin_lock_bh(&g->lock);
	g->members++;
	spin_unlock_bh(&g->lock);
}

void brutal_group_leave(struct brutal *brutal)
{
	struct brutal_group *g = brutal->group;

	if (!g)
		return;
	brutal->group = NULL;
	brutal->resv_bytes = 0;
	spin_lock_bh(&g->lock);
	g->members--;
	spin_unlock_bh(&g->lock);
	brutal_group_put(g);
}

static int brutal_set_params(struct sock *sk, sockptr_t optval, unsigned int optlen)
{
	struct brutal *brutal = inet_csk_ca(sk);
	struct brutal_params params = {};

	if (optlen < BRUTAL_PARAMS_V1_SIZE)
		return -EINVAL;
	if (copy_from_sockptr(&params, optval, min_t(unsigned int, optlen, sizeof(params))))
		return -EFAULT;
	if (optlen < sizeof(params))
		params.group_id = 0;

	if (params.rate < MIN_PACING_RATE || params.rate > MAX_PACING_RATE)
		return -EINVAL;
	if (params.cwnd_gain < MIN_CWND_GAIN || params.cwnd_gain > MAX_CWND_GAIN)
		return -EINVAL;

	lock_sock(sk);
	if (inet_csk(sk)->icsk_ca_ops != &tcp_brutal_ops) {
		release_sock(sk);
		return -ENOPROTOOPT;
	}
	if (brutal->group && READ_ONCE(brutal->group->locked)) {
		release_sock(sk);
		return -EPERM;
	}
	if (!params.group_id)
		brutal_group_leave(brutal);
	else if (!brutal->group || brutal->group->id != params.group_id) {
		struct brutal_group *g = brutal_group_get(sk, params.group_id);

		if (!g) {
			release_sock(sk);
			return -ENOMEM;
		}
		brutal_group_leave(brutal);
		brutal_group_join(brutal, g);
	}
	if (brutal->group) {
		WRITE_ONCE(brutal->group->rate, params.rate);
		WRITE_ONCE(brutal->group->cwnd_gain, params.cwnd_gain);
	}
	brutal->rate = params.rate;
	brutal->cwnd_gain = params.cwnd_gain;
	brutal_update_rate(sk);
	release_sock(sk);

	return 0;
}

static int brutal_get_params(struct sock *sk, char __user *optval, int __user *optlen)
{
	struct brutal *brutal = inet_csk_ca(sk);
	struct brutal_params params;
	int len;

	if (get_user(len, optlen))
		return -EFAULT;
	if (len < BRUTAL_PARAMS_V1_SIZE)
		return -EINVAL;
	len = min_t(int, len, sizeof(params));

	lock_sock(sk);
	if (inet_csk(sk)->icsk_ca_ops != &tcp_brutal_ops) {
		release_sock(sk);
		return -ENOPROTOOPT;
	}
	if (brutal->group) {
		params.rate = READ_ONCE(brutal->group->rate);
		params.cwnd_gain = READ_ONCE(brutal->group->cwnd_gain);
		params.group_id = brutal->group->id;
	} else {
		params.rate = brutal->rate;
		params.cwnd_gain = brutal->cwnd_gain;
		params.group_id = 0;
	}
	release_sock(sk);

	if (put_user(len, optlen) || copy_to_user(optval, &params, len))
		return -EFAULT;
	return 0;
}

static int brutal_get_version(char __user *optval, int __user *optlen)
{
	u32 version = BRUTAL_VERSION;
	int len;

	if (get_user(len, optlen))
		return -EFAULT;
	if (len < sizeof(version))
		return -EINVAL;
	len = sizeof(version);
	if (put_user(len, optlen) || copy_to_user(optval, &version, len))
		return -EFAULT;
	return 0;
}

static int brutal_tcp_setsockopt(struct sock *sk, int level, int optname, sockptr_t optval, unsigned int optlen)
{
	if (level == IPPROTO_TCP && optname == TCP_BRUTAL_PARAMS)
		return brutal_set_params(sk, optval, optlen);
	else
		return tcp_prot.setsockopt(sk, level, optname, optval, optlen);
}

static int brutal_tcp_getsockopt(struct sock *sk, int level, int optname, char __user *optval, int __user *optlen)
{
	if (level == IPPROTO_TCP && optname == TCP_BRUTAL_PARAMS)
		return brutal_get_params(sk, optval, optlen);
	else if (level == IPPROTO_TCP && optname == TCP_BRUTAL_VERSION)
		return brutal_get_version(optval, optlen);
	else
		return tcp_prot.getsockopt(sk, level, optname, optval, optlen);
}

#ifdef _TRANSP_V6_H
static int brutal_tcpv6_setsockopt(struct sock *sk, int level, int optname, sockptr_t optval, unsigned int optlen)
{
	if (level == IPPROTO_TCP && optname == TCP_BRUTAL_PARAMS)
		return brutal_set_params(sk, optval, optlen);
	else
		return tcpv6_prot.setsockopt(sk, level, optname, optval, optlen);
}

static int brutal_tcpv6_getsockopt(struct sock *sk, int level, int optname, char __user *optval, int __user *optlen)
{
	if (level == IPPROTO_TCP && optname == TCP_BRUTAL_PARAMS)
		return brutal_get_params(sk, optval, optlen);
	else if (level == IPPROTO_TCP && optname == TCP_BRUTAL_VERSION)
		return brutal_get_version(optval, optlen);
	else
		return tcpv6_prot.getsockopt(sk, level, optname, optval, optlen);
}
#endif

void __init brutal_sockopt_init(void)
{
	tcp_prot_override = tcp_prot;
	tcp_prot_override.setsockopt = brutal_tcp_setsockopt;
	tcp_prot_override.getsockopt = brutal_tcp_getsockopt;

#ifdef _TRANSP_V6_H
	tcpv6_prot_override = tcpv6_prot;
	tcpv6_prot_override.setsockopt = brutal_tcpv6_setsockopt;
	tcpv6_prot_override.getsockopt = brutal_tcpv6_getsockopt;
#endif
}

void brutal_sockopt_install(struct sock *sk)
{
	if (sk->sk_prot == &tcp_prot)
		sk->sk_prot = &tcp_prot_override;
#ifdef _TRANSP_V6_H
	else if (sk->sk_prot == &tcpv6_prot)
		sk->sk_prot = &tcpv6_prot_override;
#endif
	else
		WARN_ON_ONCE(sk->sk_family != AF_INET && sk->sk_family != AF_INET6);
}

static void brutal_restore_proto(struct proto **protp)
{
	struct proto *prot = READ_ONCE(*protp);

	if (prot == &tcp_prot_override)
		WRITE_ONCE(*protp, &tcp_prot);
#ifdef _TRANSP_V6_H
	else if (prot == &tcpv6_prot_override)
		WRITE_ONCE(*protp, &tcpv6_prot);
#endif
}

void brutal_sockopt_uninstall(struct sock *sk)
{
	brutal_restore_proto(&sk->sk_prot);
#if IS_ENABLED(CONFIG_TLS)
	if (inet_csk(sk)->icsk_ulp_ops &&
	    !strcmp(inet_csk(sk)->icsk_ulp_ops->name, "tls")) {
		struct tls_context *ctx = tls_get_ctx(sk);

		if (ctx)
			brutal_restore_proto(&ctx->sk_proto);
	}
#endif
}
EOF

echo "[4/5] 写入 brutal_rules.c ..."
cat > net/ipv4/tcp_brutal/brutal_rules.c << 'EOF'
/* TCP Brutal v2.0.1 — destination rules stub */
#include "brutal.h"

void brutal_apply_rule(struct sock *sk, struct brutal *brutal)
{
	/* No-op: default per-socket mode.
	 * Applications configure rate via setsockopt(TCP_BRUTAL_PARAMS).
	 */
}

int brutal_rules_init(void)
{
	return 0;
}

void brutal_rules_exit(void)
{
}
EOF

echo "[4/5] 写入 Kconfig ..."
cat > net/ipv4/tcp_brutal/Kconfig << 'EOF'
# SPDX-License-Identifier: GPL-2.0-only
config TCP_CONG_BRUTAL
	tristate "TCP Brutal congestion control"
	depends on INET
	default n
	help
	  TCP Brutal is Hysteria's congestion control algorithm ported to TCP.
	  It supports application-level rate shaping, group rate limiting,
	  and is compatible with IPv4 and IPv6.

	  See https://github.com/HyNetworks/tcp-brutal for details.

	  To compile as a module, choose M. If unsure, say N.
EOF

echo "[4/5] 写入 Makefile ..."
cat > net/ipv4/tcp_brutal/Makefile << 'EOF'
# SPDX-License-Identifier: GPL-2.0-only
obj-$(CONFIG_TCP_CONG_BRUTAL) += tcp_brutal.o

tcp_brutal-y := brutal_cc.o \
		brutal_sockopt.o \
		brutal_rules.o
EOF

echo "[5/5] 注入 net/ipv4/Makefile 条目（如未存在）..."
if ! grep -q 'tcp_brutal/' net/ipv4/Makefile; then
    sed -i 's|obj-$(CONFIG_TCP_CONG_BRUTAL) += tcp_brutal.o|obj-$(CONFIG_TCP_CONG_BRUTAL) += tcp_brutal/|' net/ipv4/Makefile
    echo "  net/ipv4/Makefile 已更新"
else
    echo "  net/ipv4/Makefile 条目已存在，跳过"
fi

echo ""
echo "=== TCP Brutal 2.0.1 升级完成 ==="
echo "文件列表："
ls -lh net/ipv4/tcp_brutal/
echo ""
echo "记得在 gki_defconfig 中确认以下配置："
echo "  CONFIG_TCP_CONG_BRUTAL=y"
