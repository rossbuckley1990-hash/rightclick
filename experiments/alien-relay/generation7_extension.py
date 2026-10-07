
import hashlib, json, os, pathlib, re, shutil, subprocess, sys
from huggingface_hub import HfApi
from observer import extract_transcript, compare_caption_transcript

ROOT = pathlib.Path("alien-proof")
GRADIO = str(pathlib.Path(sys.executable).with_name("gradio"))

def run(cmd, timeout=120):
    try:
        cp = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return cp.returncode, cp.stdout, cp.stderr
    except subprocess.TimeoutExpired as exc:
        return 124, exc.stdout or "", (exc.stderr or "") + "\nTIMEOUT"

def jload(s):
    try: return json.loads(s)
    except Exception: return None

def typ(x):
    try: return json.dumps(x, sort_keys=True).lower()
    except Exception: return str(x).lower()

def is_file(x):
    t=typ(x); return "filepath" in t or "filedata" in t or "audio" in t

def is_string(x):
    t=typ(x); return '"string"' in t or t.strip('"')=="string"

def clean(s):
    return re.sub(r"\s+"," ",re.sub(r"<[^>]+>"," ",s or "")).strip()

def strings(v, out):
    if isinstance(v,dict):
        for x in v.values(): strings(x,out)
    elif isinstance(v,list):
        for x in v: strings(x,out)
    elif isinstance(v,str):
        s=v.strip()
        if len(s)>=5 and not s.lower().startswith(("http://","https://","/","file:")): out.append(s)

def files(v,out):
    if isinstance(v,dict):
        for x in v.values(): files(x,out)
    elif isinstance(v,list):
        for x in v: files(x,out)
    elif isinstance(v,str):
        p=pathlib.Path(v)
        if p.exists() and p.is_file(): out.append(p)

def discover(api, queries, limit=18):
    rows=[]; seen=set(); errs=[]
    for q in queries:
        try:
            try: got=list(api.list_spaces(search=q,sort="likes",direction=-1,limit=limit))
            except TypeError: got=list(api.list_spaces(search=q,limit=limit))
            for x in got:
                sid=getattr(x,"id",None)
                if sid and sid not in seen:
                    seen.add(sid); rows.append({"id":sid,"query":q})
        except Exception as e: errs.append({"query":q,"error":repr(e)})
    return rows,errs

def contracts(spaces, mode, maxspaces=18, maxmatches=6):
    matches=[]; evidence=[]
    for ent in spaces[:maxspaces]:
        code,out,err=run([GRADIO,"info",ent["id"]],12)
        info=jload(out); rec={"space":ent["id"],"query":ent["query"],"exit_status":code,"stderr_tail":err[-500:]}
        if code!=0 or not isinstance(info,dict):
            evidence.append(rec); continue
        rec["endpoints"]=sorted(info.keys())
        for endpoint,c in info.items():
            if not isinstance(c,dict): continue
            params=c.get("parameters",[]); returns=c.get("returns",[])
            req=[p for p in params if p.get("required") is True]
            if mode=="tts":
                a=[p for p in req if is_string(p.get("type",{}))]
                b=[p for p in req if p not in a]
                ok=len(a)==1 and not b and any(is_file(r.get("type",{})) for r in returns)
            else:
                a=[p for p in req if is_file(p.get("type",{}))]
                b=[p for p in req if p not in a]
                ok=len(a)==1 and not b and any(is_string(r.get("type",{})) for r in returns)
            if ok:
                matches.append({"space":ent["id"],"query":ent["query"],"endpoint":endpoint,"input_parameter":a[0].get("name"),"contract":c})
                rec["candidate"]=endpoint
            if len(matches)>=maxmatches: break
        evidence.append(rec)
        if len(matches)>=maxmatches: break
    return matches,evidence

proof_path=ROOT/"rightclick-alien-proof.json"
proof=json.loads(proof_path.read_text(encoding="utf-8"))
gen6_ok=proof.get("semantic_success") is True
caption=clean(((proof.get("independent_postcondition") or {}).get("text_observation") or {}).get("text"))
if not caption:
    caption=clean(((proof.get("invocation") or {}).get("text_candidates") or [{}])[0].get("text"))

api=HfApi()

tts_spaces,tts_err=discover(api,["text to speech","speech synthesis","tts"],20)
tts_matches,tts_inspect=contracts(tts_spaces,"tts",20,6)
(ROOT/"generation7-tts-discovery.json").write_text(json.dumps({"spaces":tts_spaces,"errors":tts_err,"inspection":tts_inspect,"matches":tts_matches},indent=2,sort_keys=True))

tts_selected=None; tts_attempts=[]; audio=None; audio_ev={"found":False}
for c in tts_matches[:6]:
    code,out,err=run([GRADIO,"predict",c["space"],c["endpoint"],json.dumps({c["input_parameter"]:caption[:500]},separators=(",",":"))],180)
    parsed=jload(out); paths=[]; files(parsed,paths)
    att={"space":c["space"],"endpoint":c["endpoint"],"exit_status":code,"stderr_tail":err[-800:],"returned":parsed if parsed is not None else out[-2000:]}
    for p in paths:
        data=p.read_bytes()
        if len(data)<=1000: continue
        dest=ROOT/("generation7-audio"+(p.suffix or ".bin")); shutil.copy2(p,dest)
        audio=dest; tts_selected=c
        audio_ev={"found":True,"artifact_path":str(dest),"bytes":len(data),"sha256":hashlib.sha256(data).hexdigest(),"suffix":p.suffix}
        att["audio_selected"]=str(p); break
    tts_attempts.append(att)
    if audio: break
audio_ok=audio_ev.get("found") is True and audio_ev.get("bytes",0)>1000
(ROOT/"generation7-tts-invocation.json").write_text(json.dumps({"selected":tts_selected,"attempts":tts_attempts,"audio":audio_ev},indent=2,sort_keys=True))

asr_spaces,asr_err=discover(api,["speech to text","audio transcription","automatic speech recognition","whisper"],30)
asr_matches,asr_inspect=contracts(asr_spaces,"asr",64,8)
(ROOT/"generation7-asr-discovery.json").write_text(json.dumps({"spaces":asr_spaces,"errors":asr_err,"inspection":asr_inspect,"matches":asr_matches},indent=2,sort_keys=True))

asr_selected=None; asr_attempts=[]; transcript=None
if audio:
    for c in asr_matches[:6]:
        payload={c["input_parameter"]:{"path":str(audio.resolve()),"meta":{"_type":"gradio.FileData"}}}
        code,out,err=run([GRADIO,"predict",c["space"],c["endpoint"],json.dumps(payload,separators=(",",":"))],180)
        parsed=jload(out)
        candidate, observer_source = extract_transcript(parsed if parsed is not None else out, c["contract"])
        asr_attempts.append({"space":c["space"],"endpoint":c["endpoint"],"exit_status":code,"stderr_tail":err[-800:],"returned":parsed if parsed is not None else out[-2000:],"observer_source":observer_source,"transcript_candidate":candidate})
        if code==0 and candidate: asr_selected=c; transcript=clean(candidate); break
(ROOT/"generation7-asr-invocation.json").write_text(json.dumps({"selected":asr_selected,"attempts":asr_attempts,"transcript":transcript},indent=2,sort_keys=True))

comparison=compare_caption_transcript(caption, transcript)
roundtrip=comparison["observed"]
success=gen6_ok and bool(tts_selected) and audio_ok and bool(asr_selected) and roundtrip

proof["experiment"]="RIGHTCLICK Alien Relay Generation 7 — multimodal semantic round trip"
proof["recursive_path"]=(proof.get("recursive_path") or [])+[
    "runtime discovery of text-to-speech Spaces",
    "dynamically selected text -> audio capability",
    "audio artifact independently read back and hashed",
    "runtime discovery of speech-to-text Spaces",
    "dynamically selected audio -> text capability",
    "round-trip transcript independently compared with prior caption",
]
proof["generation7"]={
    "source_generation6_semantic_success":gen6_ok,
    "caption":caption,
    "tts":{"candidate_count":len(tts_spaces),"matching_contract_count":len(tts_matches),"selected":tts_selected,"attempt_count":len(tts_attempts),"audio":audio_ev,"verified":audio_ok},
    "asr":{"candidate_count":len(asr_spaces),"matching_contract_count":len(asr_matches),"selected":asr_selected,"attempt_count":len(asr_attempts),"transcript":transcript},
    "roundtrip":comparison,
}
proof["semantic_success"]=success
proof_path.write_text(json.dumps(proof,indent=2,sort_keys=True),encoding="utf-8")
print(json.dumps(proof,indent=2,sort_keys=True))
if not success: sys.exit(3)
