"""Build the hand-written smoke-test fixture (fixture.jsonl).

Each record is a list of (word, label-code) pairs so word/label alignment is
guaranteed correct. UK-English informal register, Ben's SEO/planning/dev
vocabulary. Mix of all label types plus plenty of all-KEEP transcripts
(clean dictation must survive untouched -- precision is sacred).

Label codes: K=KEEP  F=DEL_FILLER  RP=DEL_REPEAT  RA=DEL_REPARANDUM  IN=DEL_INTERREGNUM
"""
import json
from pathlib import Path

CODE = {"K": "KEEP", "F": "DEL_FILLER", "RP": "DEL_REPEAT",
        "RA": "DEL_REPARANDUM", "IN": "DEL_INTERREGNUM"}


def rec(*pairs):
    words = [p[0] for p in pairs]
    labels = [CODE[p[1]] for p in pairs]
    return words, labels


# (word, code) sequences. Written by hand.
RAW = [
    # ---- all-KEEP clean dictations (precision anchors) ----
    [("Send", "K"), ("the", "K"), ("report", "K"), ("to", "K"), ("Sarah", "K"), ("by", "K"), ("five.", "K")],
    [("Can", "K"), ("you", "K"), ("push", "K"), ("the", "K"), ("staging", "K"), ("build", "K"), ("tonight?", "K")],
    [("Book", "K"), ("the", "K"), ("planning", "K"), ("consultant", "K"), ("for", "K"), ("Thursday", "K"), ("morning.", "K")],
    [("The", "K"), ("approval", "K"), ("rate", "K"), ("in", "K"), ("Tendring", "K"), ("is", "K"), ("looking", "K"), ("solid.", "K")],
    [("Let's", "K"), ("ship", "K"), ("the", "K"), ("backlink", "K"), ("audit", "K"), ("before", "K"), ("the", "K"), ("weekend.", "K")],
    [("Ring", "K"), ("the", "K"), ("council", "K"), ("about", "K"), ("the", "K"), ("tree", "K"), ("survey.", "K")],
    [("Deploy", "K"), ("the", "K"), ("worker", "K"), ("to", "K"), ("Cloudflare", "K"), ("and", "K"), ("check", "K"), ("the", "K"), ("logs.", "K")],
    [("Add", "K"), ("a", "K"), ("canonical", "K"), ("tag", "K"), ("to", "K"), ("every", "K"), ("council", "K"), ("page.", "K")],
    [("Grab", "K"), ("a", "K"), ("coffee", "K"), ("and", "K"), ("let's", "K"), ("crack", "K"), ("on.", "K")],
    [("Reply", "K"), ("to", "K"), ("Ken", "K"), ("about", "K"), ("the", "K"), ("refund", "K"), ("first", "K"), ("thing.", "K")],
    [("The", "K"), ("Stripe", "K"), ("webhook", "K"), ("is", "K"), ("failing", "K"), ("closed", "K"), ("now.", "K")],
    [("Move", "K"), ("the", "K"), ("permission", "K"), ("into", "K"), ("user", "K"), ("settings.", "K")],
    [("Check", "K"), ("the", "K"), ("bug", "K"), ("tray", "K"), ("before", "K"), ("lunch.", "K")],
    [("Sarah", "K"), ("wants", "K"), ("the", "K"), ("odds", "K"), ("report", "K"), ("by", "K"), ("Friday.", "K")],
    [("Bump", "K"), ("the", "K"), ("analytics", "K"), ("asset", "K"), ("version", "K"), ("or", "K"), ("it", "K"), ("serves", "K"), ("stale.", "K")],

    # ---- fillers ----
    [("Send", "K"), ("the", "K"), ("report", "K"), ("to", "K"), ("um,", "F"), ("Dave.", "K")],
    [("Uh,", "F"), ("can", "K"), ("you", "K"), ("call", "K"), ("the", "K"), ("plumber?", "K")],
    [("It's", "K"), ("erm", "F"), ("due", "K"), ("on", "K"), ("Tuesday.", "K")],
    [("We", "K"), ("should", "K"), ("like", "F"), ("push", "K"), ("this", "K"), ("live.", "K")],
    [("You", "K"), ("know,", "F"), ("the", "K"), ("council", "K"), ("never", "K"), ("replied.", "K")],
    [("It's", "K"), ("basically", "F"), ("a", "K"), ("noindex", "K"), ("problem.", "K")],
    [("That's", "K"), ("sort", "F"), ("of", "F"), ("the", "K"), ("whole", "K"), ("point.", "K")],
    [("Um,", "F"), ("erm,", "F"), ("book", "K"), ("the", "K"), ("call", "K"), ("for", "K"), ("ten.", "K")],
    [("Just", "K"), ("uh", "F"), ("send", "K"), ("it", "K"), ("over", "K"), ("when", "K"), ("you", "K"), ("can.", "K")],
    [("The", "K"), ("thing", "K"), ("is", "K"), ("like", "F"), ("we", "K"), ("need", "K"), ("more", "K"), ("authority.", "K")],

    # ---- repeats ----
    [("Send", "K"), ("the", "RP"), ("the", "K"), ("invoice", "K"), ("today.", "K")],
    [("Tell", "K"), ("her", "K"), ("tell", "RP"), ("her", "RP"), ("we're", "K"), ("running", "K"), ("late.", "K")],
    [("I", "K"), ("I", "RP"), ("think", "K"), ("it's", "K"), ("ready.", "K")],
    [("We", "K"), ("need", "K"), ("to", "K"), ("to", "RP"), ("rotate", "K"), ("the", "K"), ("token.", "K")],
    [("Push", "K"), ("push", "RP"), ("it", "K"), ("to", "K"), ("main.", "K")],
    [("The", "K"), ("the", "RP"), ("deploy", "K"), ("is", "K"), ("stuck.", "K")],
    [("Can", "K"), ("can", "RP"), ("you", "K"), ("check", "K"), ("the", "K"), ("cron?", "K")],

    # ---- reparandum + interregnum (self-correction) ----
    [("Send", "K"), ("it", "K"), ("to", "K"), ("Dave", "RA"), ("no", "IN"), ("wait", "IN"), ("send", "K"), ("it", "K"), ("to", "K"), ("Sarah.", "K")],
    [("Book", "K"), ("it", "K"), ("for", "K"), ("Monday", "RA"), ("actually", "IN"), ("make", "K"), ("it", "K"), ("Tuesday.", "K")],
    [("Deploy", "K"), ("to", "K"), ("staging", "RA"), ("I", "IN"), ("mean", "IN"), ("production.", "K")],
    [("Call", "K"), ("the", "K"), ("Colchester", "RA"), ("scratch", "IN"), ("that", "IN"), ("the", "K"), ("Tendring", "K"), ("office.", "K")],
    [("Set", "K"), ("the", "K"), ("price", "K"), ("to", "K"), ("twenty", "RA"), ("no", "IN"), ("nineteen", "K"), ("ninety", "K"), ("nine.", "K")],
    [("Email", "K"), ("it", "K"), ("to", "K"), ("Ken", "RA"), ("no", "IN"), ("Richard", "K"), ("about", "K"), ("the", "K"), ("cancel.", "K")],
    [("Ship", "K"), ("the", "K"), ("blue", "RA"), ("sorry", "IN"), ("the", "K"), ("green", "K"), ("variant.", "K")],
    [("Meet", "K"), ("at", "K"), ("noon", "RA"), ("actually", "IN"), ("half", "K"), ("twelve", "K"), ("works", "K"), ("better.", "K")],

    # ---- mixed / harder ----
    [("So", "K"), ("um,", "F"), ("send", "K"), ("the", "RP"), ("the", "K"), ("file", "K"), ("to", "K"), ("Dave", "RA"), ("no", "IN"), ("Sarah.", "K")],
    [("We", "K"), ("we", "RP"), ("basically", "F"), ("need", "K"), ("the", "K"), ("audit", "K"), ("done.", "K")],
    [("Uh", "F"), ("book", "K"), ("Monday", "RA"), ("I", "IN"), ("mean", "IN"), ("Tuesday", "K"), ("please.", "K")],
    [("Push", "K"), ("it", "K"), ("live", "K"), ("um", "F"), ("actually", "IN"), ("hold", "K"), ("on", "K"), ("a", "K"), ("sec.", "K")],
    [("Ring", "K"), ("ring", "RP"), ("the", "K"), ("erm", "F"), ("planning", "K"), ("team.", "K")],

    # ---- more all-KEEP incl. tricky words that LOOK like fillers but aren't ----
    [("I", "K"), ("like", "K"), ("the", "K"), ("new", "K"), ("dashboard", "K"), ("layout.", "K")],
    [("Sort", "K"), ("the", "K"), ("leads", "K"), ("by", "K"), ("approval", "K"), ("odds.", "K")],
    [("You", "K"), ("know", "K"), ("the", "K"), ("answer", "K"), ("already.", "K")],
    [("Basically", "K"), ("everything", "K"), ("is", "K"), ("deployed.", "K")],
    [("Add", "K"), ("him", "K"), ("to", "K"), ("the", "K"), ("nurture", "K"), ("drip.", "K")],
    [("The", "K"), ("cabin", "K"), ("guides", "K"), ("are", "K"), ("live", "K"), ("now.", "K")],
    [("Confirm", "K"), ("the", "K"), ("NICEIC", "K"), ("number", "K"), ("with", "K"), ("the", "K"), ("sparky.", "K")],
    [("Rotate", "K"), ("the", "K"), ("token", "K"), ("and", "K"), ("redeploy.", "K")],
    [("Draft", "K"), ("the", "K"), ("outreach", "K"), ("email", "K"), ("but", "K"), ("don't", "K"), ("send", "K"), ("it.", "K")],
    [("Check", "K"), ("MPS", "K"), ("is", "K"), ("available", "K"), ("before", "K"), ("training.", "K")],
    [("The", "K"), ("gold", "K"), ("set", "K"), ("is", "K"), ("the", "K"), ("only", "K"), ("eval", "K"), ("that", "K"), ("counts.", "K")],

    # ---- a couple with trailing filler / correction at end ----
    [("Get", "K"), ("it", "K"), ("done", "K"), ("today", "K"), ("um.", "F")],
    [("Send", "K"), ("to", "K"), ("Sarah", "K"), ("or", "RA"), ("no", "IN"), ("Dave.", "K")],
    [("Push", "K"), ("the", "K"), ("fix", "K"), ("you", "F"), ("know.", "F")],
]


def main():
    out = Path(__file__).resolve().parent / "fixture.jsonl"
    with out.open("w", encoding="utf-8") as fh:
        for i, pairs in enumerate(RAW):
            words, labels = rec(*pairs)
            assert len(words) == len(labels), f"len mismatch at record {i}"
            src = "rule"
            obj = {"id": f"fix-{i:04d}", "source": src, "words": words, "labels": labels}
            fh.write(json.dumps(obj, ensure_ascii=False) + "\n")
    print(f"wrote {len(RAW)} records -> {out}")


if __name__ == "__main__":
    main()
