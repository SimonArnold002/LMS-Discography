# Shared helpers for the classical plan's step-0 measurements (docs/classical-plan.md §5, §8).
# Paths, the public MusicBrainz client, the rig's JSON-RPC, and the Open Opus dump.
import json, os, time, urllib.request, urllib.error

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA = os.environ.get('CLASSICAL_DATA') or os.path.join(REPO, 'sweep', 'classical')   # sweep/ is git-ignored
os.makedirs(DATA, exist_ok=True)

def data(name):
    return os.path.join(DATA, name)

# ---- public MusicBrainz: 1.15 s apart, a 503 retried; the User-Agent carries no e-mail
MB = 'https://musicbrainz.org/ws/2/'
UA = 'Discography-classical-plan/1.0 ( https://github.com/SimonArnold002/LMS-Discography )'
_last = [0.0]

def mb_get(path):
    wait = 1.15 - (time.time() - _last[0])
    if wait > 0: time.sleep(wait)
    url = MB + path + ('&' if '?' in path else '?') + 'fmt=json'
    for _ in range(3):
        _last[0] = time.time()
        try:
            req = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept': 'application/json'})
            return json.load(urllib.request.urlopen(req, timeout=60))
        except urllib.error.HTTPError as e:
            if e.code == 503: time.sleep(2); continue
            raise
    raise RuntimeError('503 x3 ' + url)

# ---- the rig, over HTTP (browse only; never play)
HOST = os.environ.get('DSC_HOST', 'plex:9000')
PLAYER = os.environ.get('DSC_PLAYER', '')

def rpc(params, player='', timeout=120):
    body = json.dumps({'id': 1, 'method': 'slim.request', 'params': [player, params]}).encode()
    req = urllib.request.Request(f'http://{HOST}/jsonrpc.js', data=body, headers={'Content-Type': 'application/json'})
    return json.load(urllib.request.urlopen(req, timeout=timeout))['result']

def player():
    """The player the service menus are browsed with: DSC_PLAYER, else 'MacBook Pro', else the first connected."""
    global PLAYER
    if PLAYER: return PLAYER
    ps = [p for p in rpc(['players', 0, 30]).get('players_loop', []) if p.get('connected')]
    pick = next((p for p in ps if p.get('name') == 'MacBook Pro'), ps[0] if ps else None)
    if not pick: raise SystemExit('no connected player; the service menus need one to browse')
    PLAYER = pick['playerid']
    return PLAYER

# ---- Open Opus: the whole database is one public-domain download (CC0)
OO_DUMP = 'https://api.openopus.org/work/dump.json'

def composers():
    path = data('work_dump.json')
    if not os.path.exists(path):
        req = urllib.request.Request(OO_DUMP, headers={'User-Agent': UA})
        open(path, 'wb').write(urllib.request.urlopen(req, timeout=120).read())
    return json.load(open(path))['composers']
