"""The Change Radar architecture figures. Run through render.ps1, which writes SVG and PNG to docs/diagrams/.

Every fact drawn here comes from the as-built system (flows, schema, solutions, setup scripts) as described in
docs/architecture.md. Change the figure here, never the SVG.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from crdiagram import C, Figure  # noqa: E402

OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parents[2] / "docs" / "diagrams"
FIGURES = {}


def figure(name):
    def wrap(fn):
        FIGURES[name] = fn
        return fn
    return wrap


# ---------------------------------------------------------------------------------------------------------------------
@figure("00-mark")
def mark():
    """The Change Radar name mark, for the document cover and header."""
    f = Figure(240, 150, "Change Radar")
    f.radar(120, 128, 104)
    return f


@figure("01-context")
def context():
    f = Figure(1600, 900, "Change Radar in context")
    # Sources
    f.group(30, 30, 330, 760, "What Microsoft is changing", C["external"], C["external_e"], "Signals")
    src = [("Service health", ["Incidents and advisories", "Microsoft Graph"]),
           ("Message Center", ["Planned changes, retirements", "Microsoft Graph"]),
           ("Microsoft 365 roadmap", ["Features in development", "Public roadmap"]),
           ("Learn pages and blogs", ["Model retirements, release", "notes, product blogs"]),
           ("Licensing and events", ["Licensing guides, Book of", "News (information only)"])]
    for i, (t, b) in enumerate(src):
        y = 85 + i * 140
        f.box(50, y, 290, 115, t, b, "#ffffff", C["external_e"], dash="6 4" if i == 4 else None)
        f.arrow([(340, y + 57), (395, y + 57), (395, 300), (445, 300)], C["external_e"], width=1.8)

    # Change Radar
    f.group(430, 30, 740, 540, "Change Radar", C["application"], C["application_e"],
            "In a dedicated Power Platform environment. Writes only to its own tables: read-only against the tenant")
    steps = [("Collect", ["Flows on a", "schedule"], "#ffffff", C["application_e"]),
             ("Fingerprint", ["What does it", "touch? AI + rules"], C["ai"], C["ai_e"]),
             ("Match", ["Which of my", "assets? Rules"], "#ffffff", C["application_e"]),
             ("Rate", ["How much does", "it matter? AI"], C["ai"], C["ai_e"]),
             ("Alert", ["Events to", "handlers"], "#ffffff", C["application_e"])]
    for i, (t, b, fill, edge) in enumerate(steps):
        x = 450 + i * 140
        f.box(x, 240, 124, 120, t, b, fill, edge, size=16.5, body_size=13.5)
        if i < 4:
            f.arrow([(x + 124, 300), (x + 140, 300)], C["application_e"], width=2)
    f.box(450, 400, 700, 70, "Change Radar's own tables", ["Signals, estate, fingerprints, exposures, ratings, events and settings"],
          "#ffffff", C["data_e"], size=15.5, body_size=13.5)
    f.box(450, 95, 700, 110, "Radar page, app and Ask Change Radar",
          ["Where people see what is changing, what it touches and how much it matters,",
           "and where they confirm, dismiss or override"], "#ffffff", C["navy"], size=16, body_size=13.5)
    f.arrow([(800, 240), (800, 205)], C["navy"], width=1.8, both=True)

    # Estate
    f.group(430, 620, 740, 240, "Your estate (read-only)", C["data"], C["data_e"], "Landscape")
    est = [("Inventory", ["Environments, apps,", "flows, agents"]), ("Solution detail", ["Solutions, components,", "prompts, callers, models"]),
           ("Tenant settings", ["Entered by an admin", "where not readable"])]
    for i, (t, b) in enumerate(est):
        f.box(455 + i * 235, 700, 215, 120, t, b, "#ffffff", C["data_e"])
    f.arrow([(800, 700), (800, 470)], C["data_e"], width=2.2, label="collected nightly, read-only", at=(800, 597))

    # People
    f.group(1240, 30, 330, 830, "People and channels", C["business"], C["business_e"], "Insights and action")
    ppl = [("Platform owner, admins", ["Radar page: triage,", "confirm, override, tune"]),
           ("Solution owners, makers", ["Cards and Ask Change", "Radar about their assets"]),
           ("Teams chats and channels", ["Cards for incidents, high", "ratings, deadlines; digest"]),
           ("Email (optional)", ["The same alerts", "by email"]),
           ("Leadership", ["Weekly digest and the", "priority matrix"])]
    for i, (t, b) in enumerate(ppl):
        y = 85 + i * 152
        f.box(1260, y, 290, 125, t, b, "#ffffff", C["business_e"], dash="6 4" if i == 3 else None)
    f.arrow([(1150, 300), (1210, 300), (1210, 400), (1258, 400)], C["business_e"], width=2.2, label="alerts", at=(1205, 290))
    f.arrow([(1258, 150), (1152, 150)], C["business_e"], width=1.8, dash="6 5", label="review", at=(1205, 140))
    f.legend(30, 865, [("AI step", C["ai"], C["ai_e"]), ("Rules or automation", "#ffffff", C["application_e"]),
                       ("Information only / optional", "#ffffff", C["external_e"], True)])
    return f


# ---------------------------------------------------------------------------------------------------------------------
KIND = {"Automated": ("#ffffff", C["application_e"]), "Rules": (C["rule_k"], C["rule_ke"]), "AI": (C["ai"], C["ai_e"]),
        "People": (C["human"], C["human_e"])}


@figure("02-value-stream")
def value_stream():
    f = Figure(1600, 600, "The platform change loop")
    stages = [("Sense", "Collect what", "Microsoft is changing", ["Automated"], "Signals and versions"),
              ("Describe", "Fingerprint: what", "does it touch?", ["AI", "Rules", "People"], "Signal fingerprints"),
              ("Relate", "Match against", "your estate", ["Rules"], "Exposures"),
              ("Judge", "Rate the impact,", "generic and for you", ["AI", "People"], "Ratings and assessments"),
              ("Inform", "Radar, cards,", "digest, Ask", ["Automated"], "Events and alerts"),
              ("Act", "Plan and make", "the change", ["People"], "Remediation and communication"),
              ("Learn", "Confirm, dismiss,", "override, tune", ["People"], "Better rules and vocabulary")]
    w, x0 = 226, 22
    for i, (name, a, b, kinds, out) in enumerate(stages):
        x = x0 + i * (w - 8)
        stage_fill = C["business"] if name in ("Act", "Learn") else C["application"]
        stage_edge = C["business_e"] if name in ("Act", "Learn") else C["application_e"]
        f.chevron(x, 60, w, 150, stage_fill, stage_edge, first=(i == 0))
        cx = x + w / 2 + (0 if i == 0 else 8)
        f.text(cx, 105, f"{i + 1}. {name}", 18, 700, C["navy"], "middle")
        f.text(cx, 138, a, 14.5, 400, C["ink"], "middle")
        f.text(cx, 160, b, 14.5, 400, C["ink"], "middle")
        # who
        f.text(x + 30, 255, "Who", 12.5, 700, C["muted"])
        cy = 268
        for k in kinds:
            fill, edge = KIND[k]
            f.chip(x + 30, cy, {"Automated": "Automated", "Rules": "Rules, no AI", "AI": "AI prompt",
                                "People": "People"}[k], fill, edge)
            cy += 30
        f.text(x + 30, 375, "Produces", 12.5, 700, C["muted"])
        if len(out) > 24:
            cut = out.rfind(" ", 0, 24)
            f.lines(x + 30, 397, [out[:cut], out[cut + 1:]], 14, 500, C["ink"])
        else:
            f.text(x + 30, 397, out, 14, 500, C["ink"])
    f.arrow([(1560, 210), (1560, 480), (10, 480), (10, 135), (22, 135)], C["business_e"], width=2.2, dash="7 5",
            label="People's corrections improve the next cycle: vocabulary, rules, feeds and caps", at=(800, 486))
    f.text(800, 550, "One cycle a night for planned change; service health every 15 minutes; people act on their own schedule.",
           14.5, 500, C["muted"], "middle")
    return f


@figure("03-process")
def process():
    f = Figure(1600, 1000, "The change management process, by role")
    lanes = [("Microsoft", 20, 140, C["external"]), ("Change Radar\n(automated)", 160, 250, C["application"]),
             ("Platform owner\nand admins", 410, 230, C["business"]), ("Solution owners\nand makers", 640, 190, "#FDF4E3"),
             ("Leadership", 830, 140, C["data"])]
    for label, y, h, fill in lanes:
        f.lane(y, h, label, fill, label_w=190)
    for x, t in ((300, "As it happens"), (840, "Nightly, 04:00 to 07:00 UTC"), (1150, "Each working day"), (1470, "Weekly")):
        f.text(x, 14, t, 13, 700, C["muted"], "middle")
    bw, bh = 168, 96

    def b(x, y, t, body, kind="auto", dash=None):
        fill, edge = {"auto": ("#ffffff", C["application_e"]), "ai": (C["ai"], C["ai_e"]), "ms": ("#ffffff", C["external_e"]),
                      "ppl": ("#ffffff", C["business_e"]), "lead": ("#ffffff", C["data_e"])}[kind]
        f.box(x, y, bw, bh, t, body, fill, edge, size=15, body_size=13, dash=dash)

    b(215, 42, "Publishes a change", ["Message Center post,", "roadmap item, incident"], "ms")
    b(215, 232, "Collect", ["Signals and the estate;", "incidents every 15 min"])
    b(410, 232, "Fingerprint", ["What each new or", "changed signal touches"], "ai")
    b(605, 232, "Match", ["Each fingerprint against", "every asset (rules)"])
    b(800, 232, "Rate", ["Generic and estate", "impact"], "ai")
    b(995, 232, "Raise events", ["Dispatch to the", "handlers that are on"])
    b(1395, 232, "Weekly digest", ["Monday: the week's", "changes, exposures"])
    b(410, 470, "Review fingerprints", ["Below the confidence", "threshold"], "ppl")
    b(800, 470, "Triage the Radar", ["Confirm or dismiss;", "override a rating"], "ppl")
    b(995, 470, "Receive cards", ["Incidents, High or", "Critical, deadlines"], "ppl")
    b(1190, 470, "Decide and assign", ["Who acts, by when,", "and who to tell"], "ppl")
    b(215, 470, "Tune", ["Vocabulary, rules,", "feeds, caps"], "ppl")
    b(1190, 685, "Remediate", ["Update the flow, move the", "model, change a setting"], "ppl")
    b(995, 685, "Ask Change Radar", ["What does this change", "mean for my apps?"], "ppl")
    b(1395, 685, "Confirm it's done", ["The exposure closes", "at the next match"], "ppl")
    b(1395, 862, "Read the digest", ["Priority matrix and", "what lands when"], "lead")

    a, e = C["application_e"], C["business_e"]
    f.arrow([(299, 138), (299, 232)], C["external_e"])
    for x in (383, 578, 773, 968):
        f.arrow([(x, 280), (x + 27, 280)], a)
    f.arrow([(494, 328), (494, 470)], C["ai_e"], dash="6 4", label="low confidence", at=(494, 400))
    f.arrow([(884, 328), (884, 470)], a, label="exposures and\nratings", at=(884, 392))
    f.arrow([(1079, 328), (1079, 470)], a, label="card", at=(1079, 400))
    f.arrow([(1163, 518), (1190, 518)], e)
    f.arrow([(1274, 566), (1274, 685)], e, label="assign", at=(1274, 627))
    f.arrow([(1163, 733), (1190, 733)], e)
    f.arrow([(1358, 733), (1395, 733)], e)
    f.arrow([(1479, 685), (1479, 610), (884, 610), (884, 566)], e, dash="6 4", label="exposure closes", at=(1050, 604))
    f.arrow([(1563, 280), (1588, 280), (1588, 910), (1563, 910)], C["data_e"], width=2)
    f.arrow([(299, 470), (299, 328)], e, dash="6 4", label="improves", at=(299, 405))
    f.legend(215, 975, [("Automated", "#ffffff", C["application_e"]), ("AI prompt", C["ai"], C["ai_e"]),
                        ("People", "#ffffff", C["business_e"]), ("Feedback", "#ffffff", C["business_e"], True)])
    return f


@figure("04-capabilities")
def capabilities():
    f = Figure(1600, 830, "Business capability map")
    cols = [("Signal management", C["external"], C["external_e"],
             [("Official signals", "Service health, Message Center", "Automated"), ("Public sources", "Roadmap, Learn, blogs, guides", "Automated"),
              ("Change tracking", "Versions, what changed", "Automated"), ("Horizons and deadlines", "Now, Imminent, Future", "Rules"),
              ("Watch list", "Topics and items you follow", "Rules")]),
            ("Estate intelligence", C["data"], C["data_e"],
             [("Inventory", "Environments, apps, flows, agents", "Automated"), ("Solution detail", "Solutions, components, prompts", "Automated"),
              ("Model tracking", "Which model each prompt uses", "Automated"), ("Solution membership", "See the estate by solution", "Automated"),
              ("Tenant settings", "Entered where not readable", "People")]),
            ("Change analysis", C["application"], C["application_e"],
             [("Fingerprinting", "AI, rules and manual", "AI"), ("Matching", "Facet rules; no AI", "Rules"),
              ("Generic rating", "Impact on any estate", "AI"), ("Estate assessment", "Impact on your estate", "AI"),
              ("Human review", "Confirm, dismiss, override", "People")]),
            ("Communication", C["business"], C["business_e"],
             [("Radar page and app", "Matrix, timeline, lists", "Automated"), ("Teams cards", "Incidents, High, deadlines", "Automated"),
              ("Weekly digest", "Monday summary", "Automated"), ("Email (optional)", "The same, by email", "Automated"),
              ("Ask Change Radar", "Questions in Teams, Copilot", "AI")]),
            ("Operations and governance", C["technology"], C["technology_e"],
             [("Configuration", "Settings, vocabulary, rules, feeds", "People"), ("Credit safeguards", "Caps, catch-up, scope", "Rules"),
              ("Access", "Reader, User, Admin roles", "People"), ("Audit trail", "Runs, handler runs, alert log", "Automated"),
              ("Install and estimate", "Checks, credit forecast", "Automated")])]
    cw = 300
    for i, (name, fill, edge, caps) in enumerate(cols):
        x = 20 + i * (cw + 12)
        f.rect(x, 20, cw, 740, fill, edge, 12, 1.8)
        f.text(x + cw / 2, 58, name, 18, 700, edge, "middle")
        for j, (t, sub, kind) in enumerate(caps):
            y = 85 + j * 133
            f.rect(x + 14, y, cw - 28, 118, "#ffffff", edge, 10, 1.4)
            f.text(x + 30, y + 32, t, 16, 600)
            f.text(x + 30, y + 57, sub, 13.5, 400, C["muted"])
            kf, ke = KIND[kind]
            f.chip(x + 30, y + 76, {"Automated": "Automated", "Rules": "Rules", "AI": "AI prompt", "People": "People"}[kind], kf, ke)
    f.legend(20, 790, [("Automated", "#ffffff", C["application_e"]), ("Rules, no AI", C["rule_k"], C["rule_ke"]),
                       ("AI prompt", C["ai"], C["ai_e"]), ("People", C["human"], C["human_e"])])
    return f


@figure("05-data")
def data_model():
    f = Figure(1600, 790, "Conceptual data model")
    W, H = 180, 58

    def ent(x, y, name, edge, sub=None, strong=False):
        f.rect(x, y, W, H, "#ffffff", edge, 8, 2.2 if strong else 1.6)
        f.text(x + W / 2, y + (25 if sub else 35), name, 15.5, 700 if strong else 600, C["ink"], "middle")
        if sub:
            f.text(x + W / 2, y + 45, sub, 12, 400, C["muted"], "middle")

    S, E, M, V, B, T = C["external_e"], C["data_e"], C["navy"], C["application_e"], C["business_e"], C["technology_e"]
    f.group(20, 20, 620, 300, "Signals: what Microsoft is changing", C["external"], S, label_size=16)
    ent(40, 95, "Feed", S, "a source to read")
    ent(240, 95, "Signal", M, "one change", True)
    ent(440, 95, "Signal version", S, "what changed, when")
    ent(40, 235, "Watch", S, "a topic people follow")
    ent(440, 235, "Signal fingerprint", S, "what it touches")
    f.group(960, 20, 620, 300, "Estate: what you run (a read-only copy)", C["data"], E, label_size=16)
    ent(980, 95, "Solution", E)
    ent(1180, 95, "Solution member", E)
    ent(1380, 95, "Asset", M, "app, flow, agent, prompt", True)
    ent(980, 235, "Tenant setting", E, "entered by an admin")
    ent(1380, 235, "Asset fingerprint", E, "what it uses")
    f.group(670, 70, 260, 300, "Matching", C["application"], V, label_size=16)
    ent(710, 140, "Exposure", M, "this change x this asset", True)
    ent(710, 280, "Assessment", M, "the impact rating", True)
    f.group(20, 390, 620, 140, "Vocabulary and rules", C["application"], V, label_size=16)
    ent(200, 450, "Rule", V, "how facets join")
    ent(440, 450, "Facet value", V, "the shared vocabulary")
    f.group(20, 570, 920, 200, "Events and alerts: what happened, who was told", C["business"], B, label_size=16)
    for i, (n, sub) in enumerate([("Event", "e.g. exposure.found"), ("Subscription", "event to handler"), ("Handler run", "one action, logged"),
                                  ("Alert log", "what was sent")]):
        ent(45 + i * 225, 650, n, B, sub)
    f.group(980, 570, 600, 200, "Running it: settings and audit", C["technology"], T, label_size=16)
    ent(1005, 640, "Config", T, "settings")
    ent(1205, 640, "Collection run", T, "each run, audited")
    f.lines(1005, 728, ["Every asset, exposure and assessment carries a source", "(live, fixture or synthetic): never mixed in one rating."], 13, 500, T)

    L = C["line"]
    f.link([(220, 124), (240, 124)], L)
    f.link([(420, 124), (440, 124)], L)
    f.link([(330, 153), (330, 264)], L)
    f.link([(220, 264), (440, 264)], L)
    f.link([(1160, 124), (1180, 124)], L)
    f.link([(1360, 124), (1380, 124)], L)
    f.link([(1470, 153), (1470, 235)], L)
    f.link([(620, 264), (690, 264), (690, 169), (710, 169)], M, 2.2, label="a signal", at=(690, 222))
    f.link([(1470, 95), (1470, 80), (912, 80), (912, 162), (890, 162)], M, 2.2, label="an asset", at=(1200, 74))
    f.link([(980, 290), (945, 290), (945, 190), (890, 190)], M, 1.8, dash="6 4", label="or a setting", at=(945, 246))
    f.link([(800, 198), (800, 280)], M, 2.2, label="rated by", at=(800, 244))
    f.link([(530, 293), (530, 390)], V, 1.8, dash="5 4", label="uses", at=(530, 352))
    f.link([(1470, 293), (1470, 480), (620, 480)], V, 1.8, dash="5 4", label="uses", at=(1230, 474))
    f.link([(380, 479), (440, 479)], V)
    f.link([(710, 309), (655, 309), (655, 552), (135, 552), (135, 650)], B, 1.8, dash="5 4", label="raises events", at=(400, 546))
    for i in range(3):
        x = 45 + i * 225 + W
        f.link([(x, 679), (x + 45, 679)], B)
    return f

@figure("06-application")
def application():
    f = Figure(1600, 1040, "Application components")
    A, D = C["application_e"], C["data_e"]
    f.group(20, 20, 1150, 1005, "ChangeRadarCore (required)", C["application"], A, "19 cloud flows, 2 AI Builder prompts, the app and its pages, 20 tables, 3 roles")

    def mini(x, y, w, t, sub=None, fill="#ffffff", edge=A, h=58):
        f.rect(x, y, w, h, fill, edge, 8, 1.4)
        f.text(x + 12, y + (24 if sub else 35), t, 14.5, 600)
        if sub:
            f.text(x + 12, y + 45, sub, 12.5, 400, C["muted"])

    f.group(40, 80, 560, 300, "Signal collectors", "#F8FBF9", A)
    for i, (t, s) in enumerate([("Service health", "every 15 min, Graph"), ("Message Center", "hourly, Graph"), ("Roadmap", "daily, public API"),
                                ("Learn page tables", "model retirements"), ("Learn page sections", "release notes"), ("RSS feeds", "product blogs"),
                                ("Web page sections", "Book of News, licensing"), ("Licensing guides", "change logs, text recognition")]):
        mini(58 + (i % 2) * 272, 120 + (i // 2) * 64, 258, t, s, C["ai"] if t == "Licensing guides" else "#ffffff", C["ai_e"] if t == "Licensing guides" else A)
    f.group(620, 80, 530, 300, "Estate collectors", "#F6FAFD", D)
    mini(640, 120, 490, "Estate inventory", "tenant-wide: Power Platform for Admins V2, delegated", edge=D)
    mini(640, 190, 490, "Dataverse detail", "solutions, components, prompts, callers: reader app", edge=D)
    f.lines(640, 290, ["Write assets, asset fingerprints, solutions and", "memberships; read-only against the tenant"], 13.5, 500, C["muted"])

    f.group(40, 400, 1110, 165, "Analysis", "#F8FBF9", A)
    for i, (t, s, ai) in enumerate([("Fingerprint signals", "AI prompt, capped", True), ("Recompute horizons", "Now, Imminent, Future", False),
                                    ("Match exposures", "rules, no AI", False), ("Assess signals", "AI prompt, capped", True),
                                    ("Record override", "who and when", False)]):
        mini(58 + i * 216, 450, 204, t, s, C["ai"] if ai else "#ffffff", C["ai_e"] if ai else A, h=70)
    f.group(40, 585, 1110, 140, "Events", "#FFFBF2", C["business_e"])
    for i, (t, s) in enumerate([("Raise signal events", "new, changed, incidents"), ("Raise deadline events", "14 and 3 days ahead"),
                                ("Readable summary", "plain-text summaries"), ("Dispatch events", "a run per subscription")]):
        mini(58 + i * 271, 635, 259, t, s, edge=C["business_e"], h=64)
    f.group(40, 745, 560, 262, "Experience", "#F7F5FC", C["technology_e"])
    mini(58, 790, 524, "Change Radar app", "model-driven: forms, views, operations", edge=C["technology_e"])
    mini(58, 856, 524, "Radar page", "matrix, timeline, estate, by solution, demo switch", edge=C["technology_e"])
    mini(58, 922, 524, "Fingerprint review page", "accept or reject fingerprints", edge=C["technology_e"])
    f.group(620, 745, 530, 262, "Data", "#F6FAFD", D)
    f.lines(640, 800, ["20 Dataverse tables (crdr_), organisation-owned", "Roles: Reader, User, Admin",
                       "Settings, vocabulary, rules, feeds, subscriptions", "Environment variables and connection references"], 14, 500, C["ink"], gap=1.6)

    f.group(1200, 20, 380, 640, "ChangeRadarHandlers", C["business"], C["business_e"], "Alerts; every handler arrives off")
    for i, (t, s) in enumerate([("Notify-Teams", "a card per event"), ("Digest-Weekly", "Monday card"), ("Notify-Email", "the same, by email"),
                                ("Digest-Email", "Monday email"), ("Handler template", "start your own")]):
        mini(1220, 85 + i * 78, 340, t, s, edge=C["business_e"], h=64, fill="#ffffff")
    f.text(1220, 500, "Switched with setup/Set-Handlers.ps1", 13.5, 600, C["business_e"])
    f.text(1220, 524, "Post to Teams; send email", 13.5, 400, C["muted"])
    f.group(1200, 690, 380, 335, "ChangeRadarAsk (optional)", C["ai"], C["ai_e"], "Copilot Studio")
    mini(1220, 755, 340, "Ask Change Radar", "agent in Teams and M365 Copilot", C["ai"], C["ai_e"], h=64)
    f.lines(1220, 860, ["Reads Change Radar's tables", "through Dataverse, as the person", "asking: no role, no data"], 13.5, 500, C["ink"])

    f.arrow([(320, 380), (320, 400)], A)
    f.arrow([(885, 380), (885, 400)], D)
    f.arrow([(595, 565), (595, 585)], A)
    f.arrow([(1130, 667), (1182, 667), (1182, 300), (1200, 300)], C["business_e"], width=2.2, label="queued\nhandler runs", at=(1182, 540))
    f.arrow([(1200, 870), (1150, 870)], C["ai_e"], width=2, label="reads", at=(1176, 850))
    return f


@figure("07-schedule")
def schedule():
    f = Figure(1600, 760, "The nightly orchestration (UTC)")
    x0, x1, t0, t1 = 330, 1560, 4 * 60, 8 * 60 + 30

    def X(hh, mm=0):
        return x0 + ((hh * 60 + mm) - t0) / (t1 - t0) * (x1 - x0)

    for h in range(4, 9):
        x = X(h)
        f.link([(x, 60), (x, 700)], C["rule"], 1.2)
        f.text(x, 48, f"{h:02d}:00", 14, 600, C["muted"], "middle")
    for h in range(4, 9):
        x = X(h, 30)
        if x < x1:
            f.link([(x, 60), (x, 700)], C["rule"], 0.8, dash="3 5")
    rows = [("Service health", None, "every 15 minutes", "collect"), ("Message Center", None, "every hour", "collect"),
            ("Estate inventory", (4, 0), "", "estate"), ("Dataverse detail", (4, 30), "", "estate"), ("Roadmap", (5, 0), "", "collect"),
            ("Learn tables and sections", (5, 15), "05:15 and 05:20", "collect"), ("RSS feeds", (5, 25), "", "collect"),
            ("Fingerprint signals", (5, 30), "AI prompt", "ai"), ("Web sections, licensing", (5, 35), "05:35 and 05:40", "collect"),
            ("Match exposures", (6, 0), "about 3 to 30 minutes", "rules"), ("Recompute horizons", (6, 0), "", "rules"),
            ("Assess signals", (6, 30), "AI prompt", "ai"), ("Deadline events", (7, 0), "", "events"), ("Weekly digest", (8, 0), "Mondays", "events")]
    style = {"collect": (C["external"], C["external_e"]), "estate": (C["data"], C["data_e"]), "ai": (C["ai"], C["ai_e"]),
             "rules": (C["rule_k"], C["rule_ke"]), "events": (C["business"], C["business_e"])}
    for i, (name, at, note, kind) in enumerate(rows):
        y = 74 + i * 44
        f.text(320, y + 23, name, 14.5, 600, C["ink"], "end")
        fill, edge = style[kind]
        if at is None:
            step = 15 if "15" in note else 60
            m = t0
            while m <= 8 * 60:
                f.rect(X(0, m) - 5, y + 6, 10, 26, fill, edge, 3, 1.2)
                m += step
            f.text(X(8, 0) + 22, y + 23, note, 13, 500, C["muted"])
        else:
            x = X(*at)
            wbar = 70 if kind in ("rules", "ai") else 46
            f.rect(x, y + 4, wbar, 30, fill, edge, 6, 1.5)
            label = note if note and ":" in note else f"{at[0]:02d}:{at[1]:02d}" + (f"  {note}" if note else "")
            f.text(x + wbar + 10, y + 24, label, 13, 500, C["muted"])
    f.legend(330, 725, [("Signal collection", C["external"], C["external_e"]), ("Estate collection", C["data"], C["data_e"]),
                        ("AI prompt", C["ai"], C["ai_e"]), ("Rules", C["rule_k"], C["rule_ke"]), ("Events and digest", C["business"], C["business_e"])])
    f.text(20, 735, "Event-driven, any time:", 13, 700, C["muted"])
    f.text(20, 754, "events, dispatch, cards", 13, 400, C["muted"])
    return f


@figure("08-technology")
def technology():
    f = Figure(1600, 980, "Technology and deployment")
    T, D = C["technology_e"], C["data_e"]
    f.group(20, 20, 1190, 940, "Your Microsoft cloud tenant", C["mist"], C["navy"])
    f.group(45, 80, 340, 250, "Microsoft Entra ID", "#ffffff", T)
    f.lines(65, 140, ["Reader app registration", "(single tenant, certificate credential)", "", "Users, admin consent for Graph", "application permissions"], 14, 500)
    f.group(45, 350, 340, 200, "Azure subscription", "#ffffff", T)
    f.box(65, 410, 300, 110, "Key Vault", ["Reader certificate; private key", "never leaves the vault"], C["technology"], T, size=15.5, body_size=13)
    f.group(45, 570, 340, 170, "Microsoft Graph", "#ffffff", T)
    f.lines(65, 630, ["Service announcements:", "service health, Message Center"], 14, 500)
    f.group(45, 760, 340, 180, "Microsoft 365", "#ffffff", T)
    f.lines(65, 820, ["Teams: cards and digest,", "as the Flow bot", "Outlook: email alerts (optional)"], 14, 500)

    f.group(410, 80, 780, 860, "Power Platform", "#ffffff", C["application_e"])
    f.group(430, 140, 740, 560, "Change Radar environment (Dataverse)", C["application"], C["application_e"], "Production or Sandbox; never the default environment")
    tiles = [("Dataverse", ["20 tables, 3 roles,", "settings and data"], C["data"], D), ("Power Automate", ["Cloud flows: 19 in Core,", "5 in Handlers"], "#ffffff", C["application_e"]),
             ("AI Builder", ["2 prompts (fingerprint,", "assessment), text recognition"], C["ai"], C["ai_e"]),
             ("Model-driven app", ["Radar and Fingerprint", "review generative pages"], "#ffffff", T),
             ("Copilot Studio", ["Ask Change Radar agent", "(optional)"], C["ai"], C["ai_e"]),
             ("Configuration", ["3 environment variables,", "4 connection references"], "#ffffff", C["line"])]
    for i, (t, b, fill, edge) in enumerate(tiles):
        f.box(455 + (i % 3) * 240, 220 + (i // 3) * 220, 220, 180, t, b, fill, edge, size=16, body_size=13.5)
    f.group(430, 720, 360, 200, "Detail environments", "#F6FAFD", D, "Any environment you list")
    f.lines(450, 800, ["Dataverse metadata: solutions,", "components, prompts, callers", "Read by the reader's application", "user (Change Radar Reader role)"], 13.5, 500)
    f.group(810, 720, 360, 200, "Power Platform admin", "#F6FAFD", D, "Tenant-wide inventory")
    f.lines(830, 800, ["Environments, apps, flows, agents", "Power Platform for Admins V2,", "delegated: a Global Reader or", "Power Platform administrator"], 13.5, 500)

    f.group(1240, 20, 340, 940, "Public internet", C["external"], C["external_e"], "Microsoft's public sites")
    for i, (t, b) in enumerate([("Microsoft 365 roadmap", ["Public roadmap API"]), ("Microsoft Learn", ["Model retirement tables,", "release notes, licensing"]),
                                ("Product blogs", ["Power Platform, Copilot", "Studio (RSS)"]), ("Licensing guides", ["PDF change logs"]),
                                ("Book of News", ["Event announcements"])]):
        f.box(1260, 90 + i * 165, 300, 135, t, b, "#ffffff", C["external_e"], size=15.5, body_size=13.5)
    f.text(1410, 935, "Plain HTTPS GET as ChangeRadar/1.0", 13, 600, C["external_e"], "middle")

    f.arrow([(1260, 300), (1195, 300)], C["external_e"], width=2.2, label="public data", at=(1225, 285))
    f.arrow([(385, 655), (430, 655)], T, width=2, label="", at=None)
    f.arrow([(385, 465), (430, 465)], T, width=2)
    f.arrow([(430, 820), (385, 820)], C["business_e"], width=2)
    f.arrow([(610, 720), (610, 702)], D, width=2)
    f.arrow([(990, 720), (990, 702)], D, width=2)
    return f


@figure("09-security")
def security():
    R, Wr, P, X, K, AI = C["data_e"], C["application_e"], C["business_e"], C["alert_e"], C["technology_e"], C["ai_e"]
    rows = [("Reader app", ["Entra app; certificate", "held in Key Vault"],
             [("Microsoft Graph", "Read: ServiceHealth.Read.All and ServiceMessage.Read.All (application, admin consent)", R, None),
              ("Detail environments", "Read: the Change Radar Reader role (solution and prompt metadata)", R, None)]),
            ("Connection owner", ["Named admin or", "service account"],
             [("Power Platform inventory", "Read: delegated, as a Global Reader or Power Platform administrator", R, None),
              ("Change Radar's tables", "Write: its own tables only, through the flows", Wr, None),
              ("Teams and Outlook", "Post and send: only through handlers, which arrive off", X, "7 5")]),
            ("People", ["Change Radar User", "or Admin role"],
             [("Change Radar's tables", "Read. User: confirm, dismiss, override. Admin: configure", P, None)]),
            ("Agent users", ["Anyone chatting with", "Ask Change Radar"],
             [("Change Radar's tables", "Read, as themselves: no role, no data", AI, "5 4")]),
            ("Dataverse service", ["The platform's service", "principal"],
             [("Key Vault", "Key Vault Secrets User, on this vault only", K, None)])]
    slot, top = 92, 70
    n = sum(len(r[2]) for r in rows)
    f = Figure(1600, top + n * slot + 90, "Identities and permissions")
    f.text(185, 40, "Identity", 15, 700, C["navy"], "middle")
    f.text(770, 40, "Permission", 15, 700, C["navy"], "middle")
    f.text(1385, 40, "Resource", 15, 700, C["navy"], "middle")
    y = top
    for i, (who, body, grants) in enumerate(rows):
        h = len(grants) * slot
        if i:
            f.link([(20, y - 1), (1580, y - 1)], C["rule"], 1)
        f.box(40, y + 8, 290, h - 16, who, body, C["technology"], K, size=16, body_size=13.5)
        for j, (res, perm, color, dash) in enumerate(grants):
            cy = y + j * slot + slot / 2
            f.arrow([(330, cy), (1200, cy)], color, width=2.2, dash=dash)
            f.rect(372, cy - 26, 800, 22, "#ffffff", None, 4, opacity=0.95)
            f.text(770, cy - 9, perm, 13.5, 500, C["ink"], "middle")
            red = color == X
            f.box(1200, cy - 27, 370, 54, res, (), C["alert"] if red else "#ffffff", X if red else C["navy"], size=15.5, dash=dash if red else None)
        y += h
    f.text(800, y + 34, "Change Radar writes only to its own tables. Anything outside it (Teams, email) goes through a handler that arrives switched off.",
           14, 600, Wr, "middle")
    f.legend(330, y + 58, [("Read", "#ffffff", R), ("Write to Change Radar", "#ffffff", Wr), ("People's roles", "#ffffff", P),
                           ("Agent: as the user", "#ffffff", AI, True), ("Outside Change Radar, off until switched on", C["alert"], X, True)])
    return f

@figure("10-roadmap")
def roadmap():
    f = Figure(1600, 640, "Baseline, current and target architectures")
    cols = [("Baseline", "Before Change Radar", C["external"], C["external_e"],
             ["Message Center emails read by hand", "Roadmap and Learn checked ad hoc", "No link to what you actually run",
              "Generic impact, decided case by case", "Alerts depend on who noticed"]),
            ("Current: release 0.3.0", "As built, November 2026", C["application"], C["application_e"],
             ["Signals from Graph, roadmap, Learn, blogs, guides", "Estate inventory and solution detail", "Fingerprint, match and rate every night",
              "Radar page, Teams cards, digest, Ask", "Three solutions; install tested twice"]),
            ("Next", "Packaging and adoption", C["business"], C["business_e"],
             ["Governance, use and operate guides", "Publish releases 0.2.0 and 0.3.0", "One-step install (Package Deployer)",
              "Monday checks with real use", "Blog series and case study"]),
            ("Target", "Backlog and enhancements", C["technology"], C["technology_e"],
             ["Solution owners manage their exposures", "Weight impact by solution risk tier", "Match changes to an ideas backlog",
              "Multi-tenant mode for client estates", "Open the signal and fingerprint model"])]
    cw = 372
    for i, (t, sub, fill, edge, items) in enumerate(cols):
        x = 20 + i * (cw + 24)
        f.rect(x, 30, cw, 560, fill, edge, 14, 1.8, "6 4" if i == 3 else None)
        f.text(x + 22, 70, t, 19, 700, edge)
        f.text(x + 22, 96, sub, 14, 500, C["muted"])
        for j, it in enumerate(items):
            y = 130 + j * 88
            f.rect(x + 18, y, cw - 36, 70, "#ffffff", edge, 9, 1.2)
            words = it.split(" ")
            l1, l2 = "", ""
            for wd in words:
                if len(l1) + len(wd) < 40 and not l2:
                    l1 += (" " if l1 else "") + wd
                else:
                    l2 += (" " if l2 else "") + wd
            f.lines(x + 36, y + (30 if l2 else 42), [l1, l2], 14.5, 500)
        if i < 3:
            f.arrow([(x + cw + 2, 310), (x + cw + 22, 310)], C["navy"], width=2.5)
    f.text(800, 625, "Target items are proposals in the backlog (ADR 0021, spec section 14): not committed.", 14, 500, C["muted"], "middle")
    return f


@figure("11-install")
def install():
    """The install in order (docs/install.md): who does each step, and in which phase."""
    f = Figure(1600, 770, "The install in order, by role")
    lx, pitch, bw, bh = 185, 140, 116, 112
    col = lambda i: lx + i * pitch  # noqa: E731
    lanes = {"az": (52, 160, "Azure owner and\nEntra admin", C["technology"]),
             "pp": (212, 310, "Power Platform\nadmin", C["application"]),
             "co": (522, 160, "Connection\nowner", C["business"])}
    for y, h, label, fill in lanes.values():
        f.lane(y, h, label, fill, label_w=170)
    for c0, c1, t in ((0, 1, "Prepare"), (2, 4, "Install the core"), (5, 7, "Data and alerts"), (8, 9, "Open up and check")):
        x0, x1 = col(c0), col(c1) + bw
        f.rect(x0, 10, x1 - x0, 32, C["mist"], C["rule"], 6, 1)
        f.text((x0 + x1) / 2, 32, t, 14.5, 700, C["navy"], "middle")
    top = {"az": 76, "pp": 236, "co": 546}
    steps = [("pp", "1. Environment", ["Dedicated, with", "Dataverse; DLP", "and credits"]),
             ("az", "2. Reader app", ["Key Vault and", "certificate;", "Graph consent"]),
             ("co", "3. Connections", ["Dataverse and", "Power Platform", "for Admins V2"]),
             ("pp", "3. Import Core", ["Managed, with a", "settings file"]),
             ("pp", "4. Reader user", ["Application", "user with the", "Reader role"]),
             ("pp", "5. Seed data", ["Settings,", "vocabulary,", "rules, feeds"]),
             ("co", "6. Connections", ["Teams; Outlook", "for email"]),
             ("pp", "6. Handlers", ["Import, then", "Set-Handlers", "turns them on"]),
             ("pp", "7. People", ["Share the app;", "User or Admin", "role"]),
             ("pp", "9. Check", ["Test-Install,", "or by hand"])]
    edge = {"az": C["technology_e"], "pp": C["application_e"], "co": C["business_e"]}
    mids = []
    for i, (lane, title, body) in enumerate(steps):
        x, y = col(i), top[lane]
        f.box(x, y, bw, bh, title, body, "#ffffff", edge[lane], size=14.5, body_size=14)
        mids.append((x, y + bh / 2))
    for i in range(len(steps) - 1):
        (x0, y0), (x1, y1) = mids[i], mids[i + 1]
        if y0 == y1:
            f.arrow([(x0 + bw, y0), (x1, y1)], C["navy"])
        else:
            gx = x0 + bw + (x1 - x0 - bw) / 2
            f.arrow([(x0 + bw, y0), (gx, y0), (gx, y1), (x1, y1)], C["navy"])
    # Step 8 is optional: below the main row, between people and the check.
    ox = (col(8) + col(9)) / 2
    f.box(ox, 392, bw, 100, "8. Optional", ["Ask, email,", "demo data"], "#ffffff", C["application_e"], size=14.5,
          body_size=14, dash="6 4")
    f.arrow([(col(8) + bw / 2, 236 + bh), (col(8) + bw / 2, 442), (ox, 442)], C["muted"], dash="6 4")
    f.arrow([(ox + bw, 442), (col(9) + bw / 2, 442), (col(9) + bw / 2, 236 + bh)], C["muted"], dash="6 4")
    f.text(800, 722, "Every setup script plans by default, writes only with -Apply, and refuses any environment but the one named.",
           14.5, 500, C["muted"], "middle")
    f.text(800, 750, "Plan for about half a day, most of it waiting for consent and the first runs.", 14.5, 500, C["muted"], "middle")
    return f


# ---------------------------------------------------------------------------------------------------------------------
def main():
    OUT.mkdir(parents=True, exist_ok=True)
    only = set(sys.argv[2:])
    for name, fn in FIGURES.items():
        if only and name not in only:
            continue
        (OUT / f"{name}.svg").write_text(fn().svg(), encoding="utf-8")
        print(f"wrote {name}.svg")


if __name__ == "__main__":
    main()
