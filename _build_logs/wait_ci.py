import os, sys, time, json, urllib.request, urllib.error, zipfile, io, shutil

TOKEN = os.environ["GH_TOKEN"]
REPO = "zh152-del/VideoCompressor-iOS"
RUN_ID = "32976141182"
DESKTOP = r"C:\Users\Administrator\Desktop"
ARTIFACT_NAME = "axo1-unsigned-ipa"
IPA_NAME = "axo1-unsigned.ipa"
OUT = os.path.join(DESKTOP, IPA_NAME)

API = "https://api.github.com"
HEADERS = {"Authorization": f"Bearer {TOKEN}", "Accept": "application/vnd.github+json"}
POLL = 20

def api_get(path):
    req = urllib.request.Request(API + path, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode("utf-8"))

def wait_run():
    while True:
        d = api_get(f"/repos/{REPO}/actions/runs/{RUN_ID}")
        status = d.get("status")
        concl = d.get("conclusion")
        print(f"[poll] run {RUN_ID} status={status} conclusion={concl}")
        if status == "completed":
            return concl
        time.sleep(POLL)

def get_artifact_url():
    d = api_get(f"/repos/{REPO}/actions/runs/{RUN_ID}/artifacts?per_page=100")
    for a in d.get("artifacts", []):
        if a.get("name") == ARTIFACT_NAME:
            return a.get("archive_download_url")
    return None

def download_ipa():
    url = get_artifact_url()
    if not url:
        raise RuntimeError("未找到 artifact: " + ARTIFACT_NAME)
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
    z = zipfile.ZipFile(io.BytesIO(data))
    names = z.namelist()
    print("[zip] entries:", names)
    ipa_in = next((n for n in names if n == IPA_NAME or n.endswith("/" + IPA_NAME)), None)
    if not ipa_in:
        # try first .ipa
        ipa_in = next((n for n in names if n.endswith(".ipa")), None)
    if not ipa_in:
        raise RuntimeError("zip 中未找到 .ipa 文件")
    with z.open(ipa_in) as src, open(OUT, "wb") as dst:
        shutil.copyfileobj(src, dst)
    return OUT

if __name__ == "__main__":
    concl = wait_run()
    if concl != "success":
        print(f"[FAIL] CI 结论: {concl}")
        sys.exit(1)
    print("[ok] CI 成功，开始下载 artifact")
    path = download_ipa()
    size = os.path.getsize(path)
    print(f"[done] 已保存到桌面: {path}  ({size} 字节)")
