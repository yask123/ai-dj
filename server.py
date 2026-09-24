"""AI DJ web app: pick two songs from YouTube, pick a brain, watch it perform.  run: .venv/bin/python server.py  -> http://localhost:8765"""
import json
import queue
import threading
import time
import traceback
import uuid
from pathlib import Path

import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import mixlab

ROOT = Path(__file__).parent
app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origin_regex=r"https://(yask\.dev|www\.yask\.dev|[a-z0-9-]+\.vercel\.app)|http://(localhost|127\.0\.0\.1)(:\d+)?",
                   allow_methods=["*"], allow_headers=["*"])
JOBS = {}
KEY = (ROOT / ".dj_key").read_text().strip() if (ROOT / ".dj_key").exists() else ""


def check(key):
    if KEY and key != KEY:
        raise HTTPException(401, "wrong or missing access key")


def busy():
    return any(not j["done"] for j in JOBS.values())

BRAINS = [
    {"id": "jev", "name": "Jev", "by": "TypeSafe · typed decisions", "tag": "~150 ms"},
    {"id": "anthropic/claude-haiku-4.5", "name": "Claude Haiku 4.5", "by": "Anthropic", "tag": "~1.2 s"},
    {"id": "anthropic/claude-sonnet-5", "name": "Claude Sonnet 5", "by": "Anthropic", "tag": "~2 s"},
    {"id": "google/gemini-3.8-flash", "name": "Gemini 3.8 Flash", "by": "Google", "tag": "~2 s"},
    {"id": "random", "name": "Random", "by": "coin flips", "tag": "0 ms"},
]


@app.get("/")
def index():
    return FileResponse(ROOT / "web" / "index.html")


@app.get("/dj/backend.json")
def backend_json():
    return {"url": ""}  # served locally: same origin


@app.get("/api/health")
def health(key: str = ""):
    return {"ok": True, "busy": busy(), "authed": (not KEY) or key == KEY}


@app.get("/api/brains")
def brains():
    return BRAINS


@app.get("/api/search")
def search(q: str, key: str = ""):
    check(key)
    return mixlab.search(q)


class MixReq(BaseModel):
    a: str
    b: str
    brain: str = "jev"
    bars: int = 8
    key: str = ""


@app.post("/api/mix")
def mix(r: MixReq):
    check(r.key)
    if sum(1 for j in JOBS.values() if not j["done"]) >= 3:
        raise HTTPException(429, "the booth is packed, try again in a minute")
    jid = uuid.uuid4().hex[:8]
    q = queue.Queue()
    busy_before = busy()
    JOBS[jid] = {"q": q, "events": [], "done": False}

    def emit(e):
        e["t"] = round(time.time(), 2)
        JOBS[jid]["events"].append(e)
        q.put(e)

    def work():
        try:
            if busy_before:
                emit({"type": "step", "text": "another set is playing, you're next in line"})
            emit({"type": "step", "text": "cueing up both records"})
            s = mixlab.run_job(jid, r.a, r.b, r.brain, max(6, min(r.bars, 24)), emit)
            emit({"type": "done", "video": f"/out/mix_{jid}.stage.mp4", "audio": f"/out/mix_{jid}.mp3", "summary": s})
        except Exception as ex:
            traceback.print_exc()
            emit({"type": "error", "text": str(ex)[:400]})
        JOBS[jid]["done"] = True
    threading.Thread(target=work, daemon=True).start()
    return {"job": jid}


@app.get("/api/jobs/{jid}/events")
def events(jid: str, request: Request, key: str = ""):
    check(key)
    if jid not in JOBS:
        raise HTTPException(404, "unknown job")
    job = JOBS[jid]
    start = int(request.headers.get("last-event-id", -1)) + 1  # resume after a dropped connection

    def gen():
        sent = start
        yield "retry: 1500\n\n"
        last = time.time()
        while True:
            evs = job["events"]
            while sent < len(evs):
                yield f"id: {sent}\ndata: {json.dumps(evs[sent], default=str)}\n\n"
                sent += 1
                last = time.time()
            if time.time() - last > 10:
                yield ": keepalive\n\n"
                last = time.time()
            if job["done"] and sent >= len(job["events"]):
                break
            time.sleep(0.1)
    return StreamingResponse(gen(), media_type="text/event-stream")


app.mount("/out", StaticFiles(directory=ROOT / "out"), name="out")

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8765, log_level="warning")
