"""Build the clean-source corpus (ml/data/clean/*.txt).

Each line = one clean transcript (the unit of corruption); may hold 1-6
sentences. Sources:
  seed_pours.txt   - Ben's 226 cleaned pours (real)
  seed_log.txt     - polished real log transcripts (cleaner variant)
  template.txt     - slot/template generation in Ben's registers
  ollama.txt       - gemma4:latest generated, batched + checkpointed

Usage:
  python gen/build_corpus.py templates      # fast, deterministic
  python gen/build_corpus.py ollama N       # N=target ollama lines
  python gen/build_corpus.py all N
"""
from __future__ import annotations
import sys, os, re, random, json, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C

random.seed(1234)
os.makedirs(C.CLEAN_DIR, exist_ok=True)

# ---------------------------------------------------------------------------
# Slot vocabularies drawn from Ben's real domains.
NAMES = ["Dave", "Sarah", "Ben", "Tom", "Charlie", "Jess", "Mark", "Katie",
         "Ryan", "Sophie", "Liam", "Emma", "Josh", "Nadia", "Kat Fielding",
         "Ken", "Richard", "the client", "the dev team", "the designer"]
TRADES = ["brickwork", "roofing", "spray foam removal", "asbestos surveys",
          "window repair", "electrical", "plumbing", "landscaping",
          "tree surgery", "extensions", "loft conversions", "conveyancing"]
COUNCILS = ["Uxbridge", "Tendring", "Hillingdon", "Colchester", "Portsmouth",
            "Clacton", "Croydon", "Ealing", "Basildon", "Chelmsford"]
PROJECTS = ["PlanWatch", "MedsTracker", "TenantCheck", "BargainHound",
            "TrackForge", "LeadPipe", "Bouncer", "NotifOwl",
            "SurveySentinel", "the SEO system", "PropBet",
            "QuickVan Movers", "WindowFixers", "GhostFrame"]
SEO_TERMS = ["backlinks", "referring domains", "domain authority", "anchor text",
             "the sitemap", "canonical tags", "schema markup", "internal links",
             "the approval-odds engine", "the keyword matrix", "organic traffic",
             "the SERP", "the Ahrefs data", "the DataForSEO backlinks",
             "the geo probe", "topical authority"]
TOOLS = ["Cloudflare", "Oracle", "Stripe", "the Discord", "Ahrefs", "DataForSEO",
         "Google Search Console", "Google My Business", "PM2", "the Meta pixel",
         "the CAPI", "Ollama", "Claude", "Opus", "Codex", "the Oracle server"]
FILES = ["config.json", "pours.json", "the client.json", "DESIGN.md",
         "the .env file", "index.astro", "corrupt_rules.py", "the middleware",
         "the sitemap.xml", "wrangler.toml", "the launchd plist"]
URLS = ["planningalerts.example.co.uk", "medstracker.example.co.uk", "phonefixers.example.com",
        "greenquotes.example.com", "windowfixers.example.info", "localhost:3001",
        "the staging URL", "acmemedia.example.com"]
NUMS = ["three", "five", "ten", "twenty", "fifty", "a hundred", "two hundred",
        "five hundred", "a couple", "a dozen", "thirty", "forty"]
MONEY = ["£9.99", "£24", "£29", "£49 a month", "£149 a month", "£249",
         "a few quid", "loads of money", "a needless amount of money"]
ACTIONS = ["push it live", "run it through the config", "deploy it to Cloudflare",
           "check the backlinks", "build the scrapers", "update the memory",
           "regenerate the council pages", "rotate the credentials",
           "wire up the pixel", "spin up a new business", "fix the schema",
           "chase the ranking", "resurrect the domain", "scrape the marketplace"]

def pick(seq):
    return random.choice(seq)

# ---------------------------------------------------------------------------
# Template patterns. {slots} filled from the vocabularies. Registers:
# instruction, question, note-to-self, email/slack, observation.
TEMPLATES = [
    # instructions to an assistant
    "Can you {act} for me and let me know when it's done?",
    "Go ahead and {act}, then update me in {tool}.",
    "I need you to {act} before end of day.",
    "Right, let's {act} and get {proj} moving.",
    "Send the report to {name} and cc {name2}.",
    "Have {name} take a look at {file} when they get a chance.",
    "Build me a script that checks {seo} and tells me if it's any good.",
    "Push the {proj} redesign to {url} and run it through {tool}.",
    "Set up a channel in {tool} for the {trade} leads so it's neat and tidy.",
    "Orchestrate this and have Opus doing most of the heavy lifting.",
    "Update the memory so you stop binding {proj} to {council} {trade}.",
    "Place the scrapers on {tool} and update me each day with the results.",
    "Give me another {num} {trade} leads in the {council} area.",
    "Deploy {proj} to {tool} and make sure the {seo} is correct.",
    # questions about business / SEO / code
    "What goes into building {proj} ourselves?",
    "Do I need to pay for {tool}, and if so how much?",
    "What's our criteria as to what counts as a good domain?",
    "How does the flow go when we check a domain on {tool}?",
    "Is {url} a good buy, what do you think about the authority?",
    "Why do all of these domains have {council} in the name?",
    "Can't crazy domains like that be resurrected somehow?",
    "How do we get there at the same time as these people?",
    "So is the problem that they don't know what their job is?",
    "Where do these marketplaces actually get their domains from?",
    "What's the difference between {seo} and {seo2} for ranking {url}?",
    "Should I be worried about {seo} on {proj} right now?",
    # notes-to-self
    "Note to self: {act} before the {proj} launch.",
    "Remember to {act} once {name} signs off on it.",
    "Don't forget the {trade} pages still need the {seo} fixing.",
    "The {council} pilot is parked until we sort the {seo}.",
    # emails / slack
    "Hi {name}, just checking the {proj} work is on track for this week.",
    "Morning {name}, can we get {money} sorted for the {trade} campaign?",
    "Thanks {name}, I'll get {file} over to you by tomorrow.",
    "Quick one {name} - is the {url} deploy live yet?",
    "Following up on {proj}: we still need to {act}.",
    # observations
    "I'm manually checking them on Ahrefs and they're all shit.",
    "We've let {proj} run stale but I'm going to push it again now.",
    "This isn't our goal for link building or buying domains.",
    "I literally have an entire project for {url} already.",
    "The repair shop will be in {council} and the leads go to {name}.",
    "It's gotten too caught up in {proj} and {trade}.",
    "I only want .co.uk and .com, not any .uk domains.",
    "That was just going to cost me a needless amount of money.",
    "The {trade} vertical on {proj} is doing better than the {seo} play.",
    "Set the price at {money} for the {proj} tier and see if it converts.",
]

# Short fragments (3-8 words) — Ben's real dictations skew short, so we need a
# healthy tail of these.
SHORT_TEMPLATES = [
    "{trade} in {council}", "Check out {url}", "Give me {num} more now",
    "{proj} versus {proj2}", "Is {url} a good buy?", "Just {act}.",
    "Push {proj} live.", "{act} for me.", "What about {council}?",
    "How much is {tool}?", "Deploy it to {tool}.", "Any update on {proj}?",
    "Find me {num} {trade} leads.", "Rotate the {tool} credentials.",
    "Fix the {seo} on {url}.", "Chase the {seo} for {proj}.",
    "Sort out {money} for {name}.", "Ping {name} about it.",
    "Where's the {file}?", "Resurrect that domain.", "Scrape the marketplace.",
    "Ten or twenty more.", "Keep it as is.", "Make it {num}.",
    "Send it to {name}.", "Get {name} on {proj}.", "{council} versus {council2}",
]
SLOT_FN_SHORT = None  # populated after SLOT_FN defined below

SLOT_FN = {
    "act": lambda: pick(ACTIONS), "name": lambda: pick(NAMES),
    "name2": lambda: pick(NAMES), "proj": lambda: pick(PROJECTS),
    "proj2": lambda: pick(PROJECTS), "tool": lambda: pick(TOOLS),
    "seo": lambda: pick(SEO_TERMS), "seo2": lambda: pick(SEO_TERMS),
    "trade": lambda: pick(TRADES), "council": lambda: pick(COUNCILS),
    "council2": lambda: pick(COUNCILS), "url": lambda: pick(URLS),
    "file": lambda: pick(FILES), "num": lambda: pick(NUMS),
    "money": lambda: pick(MONEY),
}

def fill(tpl: str) -> str:
    def rep(m):
        return SLOT_FN[m.group(1)]()
    s = re.sub(r"\{(\w+)\}", rep, tpl)
    # Slot values may start with an article after a template's own article
    # ("the {seo}" + "the sitemap" -> "the the sitemap"): collapse it, since
    # an accidental adjacent repeat in the CLEAN corpus would be labeled KEEP
    # and poison the DEL_REPEAT signal.
    s = re.sub(r"\b([Tt]he|[Aa]n?) the ", r"\1 ", s)
    return s

def gen_templates(target=16000):
    out, seen = [], set()
    tries = 0
    while len(out) < target and tries < target * 30:
        tries += 1
        roll = random.random()
        if roll < 0.28:
            # short single fragment (3-8 words)
            s = fill(pick(SHORT_TEMPLATES))
        else:
            # single or multi-sentence (concatenate 1-3 normal templates)
            n = random.choices([1, 2, 3], weights=[7, 3, 1])[0]
            parts = [fill(pick(TEMPLATES)) for _ in range(n)]
            s = " ".join(parts)
        key = s.lower()
        if key in seen:
            continue
        seen.add(key)
        out.append(s)
    return out

# ---------------------------------------------------------------------------
# Ollama clean-sentence generation.
OLLAMA_SYS = (
    "You generate short, realistic DICTATION transcripts as if spoken by a "
    "busy UK software entrepreneur named Ben into a voice-notes app. He works "
    "on SEO, web development, local-business lead generation, planning-permission "
    "data, and trading bots. His style: informal British English, direct, "
    "sometimes blunt (mild swearing ok), uses UK spellings, product names, "
    "councils, URLs, file paths and numbers. Each transcript is ALREADY CLEAN "
    "(no filler words, no stutters, no self-corrections) - just what he meant. "
    "Mix instructions to an assistant, questions about business/SEO/code, "
    "notes-to-self, and short emails/Slack messages. Vary length from 3 to "
    "120 words and from 1 to 6 sentences."
)

OLLAMA_TASK = (
    "Produce {k} DIFFERENT clean dictation transcripts. Return ONLY a JSON "
    "array of strings, no commentary. Vary topic and length. Theme hint for "
    "this batch: {theme}."
)
THEMES = [
    "chasing SEO rankings and backlinks", "deploying a website to Cloudflare",
    "buying and resurrecting expired domains", "trade lead generation for builders",
    "planning permission approval odds", "debugging a Python or Swift bug",
    "Stripe billing and subscriptions", "hiring or delegating to the team",
    "a new business idea to spin up", "the trading bot and backtests",
    "reviewing an SEO audit", "setting up Meta pixel and CAPI tracking",
    "asking the assistant to orchestrate a big build", "quick notes to self",
    "a Slack message to a client or contractor", "frustration with bad domains",
    "scraping marketplaces on the Oracle server", "the phone repair side project",
    "the medicine tracking product", "the planning alerts product",
]

def gen_ollama(target, out_path):
    seen = set()
    if os.path.exists(out_path):
        for l in open(out_path, encoding="utf-8"):
            seen.add(l.strip().lower())
    have = len(seen)
    print(f"[ollama] resuming: {have} already, target {target}")
    fails = 0
    while have < target:
        k = random.randint(20, 30)
        theme = pick(THEMES)
        msgs = [{"role": "system", "content": OLLAMA_SYS},
                {"role": "user", "content": OLLAMA_TASK.format(k=k, theme=theme)}]
        try:
            resp = C.ollama_chat(msgs, temperature=1.0, fmt="json")
        except Exception as e:
            print("[ollama] error", e); fails += 1
            if fails > 20:
                break
            continue
        arr = C.extract_json(resp)
        if not isinstance(arr, list):
            # some models wrap in {"transcripts":[...]}
            if isinstance(arr, dict):
                for v in arr.values():
                    if isinstance(v, list):
                        arr = v; break
        if not isinstance(arr, list):
            fails += 1
            continue
        added = 0
        with open(out_path, "a", encoding="utf-8") as f:
            for s in arr:
                if not isinstance(s, str):
                    continue
                s = " ".join(s.split()).strip()
                w = len(s.split())
                if w < 2 or w > 130:
                    continue
                key = s.lower()
                if key in seen:
                    continue
                seen.add(key); f.write(s + "\n"); added += 1; have += 1
        print(f"[ollama] +{added} (total {have}/{target}) theme={theme[:30]}")
    print(f"[ollama] done: {have}")

# ---------------------------------------------------------------------------
def write_lines(path, lines):
    with open(path, "w", encoding="utf-8") as f:
        for l in lines:
            f.write(l.strip() + "\n")

def build_seeds():
    pours = C.load_pours()
    log = C.load_real_log()
    write_lines(os.path.join(C.CLEAN_DIR, "seed_pours.txt"), pours)
    write_lines(os.path.join(C.CLEAN_DIR, "seed_log.txt"), log)
    print(f"[seeds] pours={len(pours)} log={len(log)}")

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "all"
    build_seeds()
    if cmd in ("templates", "all"):
        tpl = gen_templates(16000)
        write_lines(os.path.join(C.CLEAN_DIR, "template.txt"), tpl)
        print(f"[templates] wrote {len(tpl)}")
    if cmd in ("ollama", "all"):
        target = int(sys.argv[2]) if len(sys.argv) > 2 else 8000
        gen_ollama(target, os.path.join(C.CLEAN_DIR, "ollama.txt"))

if __name__ == "__main__":
    main()
