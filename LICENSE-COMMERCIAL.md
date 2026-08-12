# Commercial License

Tokkah is dual-licensed.

| | Open-source license | Commercial license |
|---|---|---|
| **Terms** | [GNU AGPL v3](LICENSE) | this document |
| **Price** | free, forever | negotiated |
| **You must publish your source** | yes, if you serve users a modified version | no |
| **Best for** | self-hosting, forks, research, internal tools, any project that is itself open source | closed-source products, SaaS, embedding Tokkah in something you sell |

**You do not need to talk to us to use Tokkah.** Take it, deploy it, fork it,
build a business on it — the AGPL grants all of that for free. The commercial
license exists for exactly one situation: you want the software **without** the
AGPL's obligation to publish your own source code.

---

## Which one applies to me?

**The AGPL is enough — no payment, no conversation — if any of these is true:**

- You run Tokkah for yourself, your team, or your company's internal use.
- You deploy it unmodified (the source is already public; you just link to it).
- You modified it and you publish your modified source to your users.
- You are a researcher, student, hobbyist, or non-profit.
- Your own product is licensed under AGPL v3 or a compatible license.

**You need a commercial license if:**

- You ship Tokkah — modified or not — inside a **closed-source** product.
- You run a **service** built on modified Tokkah and will not publish the
  modified source to the people using that service.
- Your legal team will not accept copyleft obligations in your codebase.

That last one is the honest common case. Large platforms do not publish their
calling stacks. The AGPL does not forbid them from using Tokkah — it requires
them to open their derivative work if they serve it to users. When that is
unacceptable, the commercial license is the alternative.

---

## What the commercial license grants

A perpetual, worldwide, non-exclusive right to use, modify, and distribute
Tokkah **without** the AGPL's source-disclosure requirements (AGPL §5 and §13),
for the products and term agreed in a signed agreement. It typically includes:

- No obligation to publish your modifications or your surrounding source.
- The right to sublicense Tokkah as part of your product to your end users.
- Written warranty and indemnity terms (the AGPL provides none).
- Optional: support, a security-response SLA, and prioritized fixes.

## What it costs

Pricing is negotiated per deal and depends on scale and scope. The principle:
a small company paying to avoid copyleft should pay a small amount; a platform
serving hundreds of millions of calls should pay in proportion to that value.
Terms both sides agree are fair, in writing, before any obligation attaches.

## How to start

Email **licensing@tokkah.com** with:

1. Your company and product.
2. How Tokkah would be used (embedded / self-hosted / modified).
3. Rough scale — calls or monthly active users.

You will get a written proposal. Nothing is owed for evaluation: **evaluating
Tokkah, in any depth, under the AGPL, costs nothing and requires no permission.**

---

## Notes, stated plainly

- **The AGPL is real open source.** It is OSI-approved and FSF-published. This
  is not "source available" with a marketing label — it is the same license
  family used by MongoDB (historically), Grafana, Mastodon, and Nextcloud.
- **Older versions stay under their old license.** Everything published before
  commit `6375ae4` was released under the MIT license, and that grant cannot be
  withdrawn. Anyone may keep using those snapshots under MIT terms forever. The
  AGPL applies to this commit onward.
- **We can offer a commercial license because we own the copyright.** Every
  contributor signs off under the terms in [CONTRIBUTING.md](CONTRIBUTING.md),
  which is what keeps dual-licensing possible. Without that, no one — including
  us — could relicense contributed code.
- **This document is a summary, not the contract.** The binding terms are in the
  signed agreement. It has not been reviewed by a lawyer yet; get your own
  counsel to review before relying on it.
