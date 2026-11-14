#!/usr/bin/env python3
"""Generate, rig and animate a character with Meshy, then save it for Spryts.

Usage: python3 tools/make_character.py <character id>

Reads the prompt from Characters/<id>.json ("meshyPrompt") and the key from .env
(MESHY_API_KEY). Progress is saved after every step, so running it again resumes
where it stopped instead of spending credits twice.
"""
import json
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
API = "https://api.meshy.ai/openapi"
CLIPS = {
    "idle": ["idle"],
    "walk": ["walking", "walk"],
    "run": ["running", "run"],
    "jump": ["jump"],
    "wave": ["wave", "waving", "greet"],
}


def read_key():
    env = ROOT / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            line = line.strip()
            if line.startswith("MESHY_API_KEY="):
                return line.split("=", 1)[1].strip().strip('"')
    sys.exit("No MESHY_API_KEY found in .env")


KEY = read_key()


def call(method, path, body=None):
    cmd = ["curl", "-sS", "-K", "-", "-X", method, API + path]
    if body is not None:
        cmd += ["-H", "Content-Type: application/json", "-d", json.dumps(body)]
    # The key goes in on stdin so it never shows up in the process list.
    out = subprocess.run(cmd, input='header = "Authorization: Bearer %s"\n' % KEY,
                         capture_output=True, text=True)
    try:
        return json.loads(out.stdout)
    except ValueError:
        sys.exit("Unexpected reply from Meshy for %s %s:\n%s\n%s" % (method, path, out.stdout[:600], out.stderr[:300]))


def find(obj, key):
    """First value stored under `key` anywhere in a nested reply."""
    if isinstance(obj, dict):
        if obj.get(key):
            return obj[key]
        for value in obj.values():
            hit = find(value, key)
            if hit:
                return hit
    elif isinstance(obj, list):
        for value in obj:
            hit = find(value, key)
            if hit:
                return hit
    return None


def start(path, body, label):
    reply = call("POST", path, body)
    task = reply.get("result") if isinstance(reply, dict) else None
    if not isinstance(task, str):
        sys.exit("%s could not start: %s" % (label, json.dumps(reply)[:600]))
    return task


def wait(path, task, label):
    while True:
        reply = call("GET", "%s/%s" % (path, task))
        status = reply.get("status")
        print("  %s: %s %s%%" % (label, status, reply.get("progress", 0)), flush=True)
        if status == "SUCCEEDED":
            return reply
        if status in ("FAILED", "CANCELED"):
            sys.exit("%s failed: %s" % (label, json.dumps(reply.get("task_error"))))
        time.sleep(6)


def download(url, dest):
    subprocess.run(["curl", "-sSL", "-o", str(dest), url], check=True)


def pending():
    """Every character with a prompt whose model has not been generated yet."""
    ids = []
    for path in sorted((ROOT / "Characters").glob("*.json")):
        sheet = json.loads(path.read_text())
        if not sheet.get("meshyPrompt"):
            continue
        folder = ROOT / "Characters" / "models" / sheet.get("meshyModel", sheet["id"])
        if not (folder / "idle.usdz").exists():
            ids.append(sheet["id"])
    return ids


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    if sys.argv[1] == "--all":
        todo = pending()
        if not todo:
            print("Every character with a prompt already has its model.")
        for cid in todo:
            print("\n=== %s ===" % cid)
            make(cid)
        return
    make(sys.argv[1])


def make(cid):
    sheet = json.loads((ROOT / "Characters" / (cid + ".json")).read_text())
    prompt = sheet.get("meshyPrompt")
    if not prompt:
        sys.exit("Characters/%s.json has no meshyPrompt" % cid)
    out = ROOT / "Characters" / "models" / sheet.get("meshyModel", cid)
    out.mkdir(parents=True, exist_ok=True)
    state_file = out / "state.json"
    state = json.loads(state_file.read_text()) if state_file.exists() else {}

    def save():
        state_file.write_text(json.dumps(state, indent=2))

    balance = call("GET", "/v1/balance")
    print("Meshy credits available:", balance.get("balance", balance))
    print("This run uses roughly 50 credits when started from scratch.\n")

    if "preview" not in state:
        print("1/4 Shaping the character")
        state["preview"] = start("/v2/text-to-3d", {
            "mode": "preview", "prompt": prompt, "ai_model": "latest",
            "pose_mode": "a-pose", "topology": "triangle",
            "target_polycount": 30000, "should_remesh": True,
        }, "Preview")
        save()
    wait("/v2/text-to-3d", state["preview"], "shape")

    if "refine" not in state:
        print("2/4 Painting the character")
        state["refine"] = start("/v2/text-to-3d", {
            "mode": "refine", "preview_task_id": state["preview"],
        }, "Refine")
        save()
    refined = wait("/v2/text-to-3d", state["refine"], "paint")
    if refined.get("thumbnail_url") and not (out / "thumbnail.png").exists():
        download(refined["thumbnail_url"], out / "thumbnail.png")

    if "rig" not in state:
        print("3/4 Adding a skeleton")
        state["rig"] = start("/v1/rigging", {
            "input_task_id": state["refine"], "height_meters": 1.2,
        }, "Rigging")
        save()
    wait("/v1/rigging", state["rig"], "skeleton")

    print("4/4 Animating")
    library = call("GET", "/v1/animations/library")
    items = library if isinstance(library, list) else next(
        (v for v in library.values() if isinstance(v, list)), [])
    (ROOT / "Characters" / "models" / "library.json").write_text(json.dumps(items, indent=1))
    state.setdefault("actions", {})
    state.setdefault("clips", {})
    for clip, terms in CLIPS.items():
        if (out / (clip + ".usdz")).exists():
            continue
        if clip not in state["actions"]:
            pick = None
            for term in terms:
                exact = [i for i in items if str(i.get("name", "")).lower() == term]
                loose = [i for i in items if term in str(i.get("name", "")).lower()]
                # The plainest name is usually the plainest motion.
                loose.sort(key=lambda i: len(str(i.get("name", ""))))
                if exact or loose:
                    pick = (exact or loose)[0]
                    break
            if pick is None:
                print("  no library animation found for", clip)
                continue
            state["actions"][clip] = {"action_id": pick["action_id"], "name": pick.get("name")}
            save()
        if clip not in state["clips"]:
            state["clips"][clip] = start("/v1/animations", {
                "rig_task_id": state["rig"],
                "action_id": state["actions"][clip]["action_id"],
                "post_process": {"operation_type": "fbx2usdz"},
            }, "Animation " + clip)
            save()
        done = wait("/v1/animations", state["clips"][clip], clip)
        (out / (clip + ".json")).write_text(json.dumps(done, indent=2))
        usdz = find(done, "processed_usdz_url")
        glb = find(done, "animation_glb_url")
        if glb:
            download(glb, out / (clip + ".glb"))
        if usdz:
            download(usdz, out / (clip + ".usdz"))
            print("  saved %s.usdz (%s)" % (clip, state["actions"][clip]["name"]))
        else:
            print("  %s finished but returned no USDZ file; the reply is saved in %s.json" % (clip, clip))

    print("\nDone. Files are in", out)
    print("Run Spryts again and %s will join the others." % sheet.get("name", cid))


if __name__ == "__main__":
    main()
