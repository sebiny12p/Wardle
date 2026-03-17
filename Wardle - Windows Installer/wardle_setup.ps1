<#
.SYNOPSIS
    WARDLE
#>

$INSTALL_DIR = "C:\Wardle"
$WEB_ROOT = "$INSTALL_DIR\www"
$DB_PATH = "$INSTALL_DIR\data\wardle.db"
$WEBSOCKETD_URL = "https://github.com/joewalnes/websocketd/releases/download/v0.4.1/websocketd-0.4.1-windows_amd64.zip"

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "ERROR: Please run as Administrator!" -ForegroundColor Red
    Start-Sleep -Seconds 3
    Exit
}

Stop-Process -Name "websocketd" -ErrorAction SilentlyContinue
Stop-Process -Name "python" -ErrorAction SilentlyContinue

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " STEP 1: PREPARING ENVIRONMENT" -ForegroundColor Cyan
Write-Host "=========================================="

# FIX: Force removal of the state directory (pipes) to ensure a fresh start on install
if (Test-Path "$INSTALL_DIR\data\pipes") {
    Write-Host "   [..] Cleaning up old game state..."
    Remove-Item "$INSTALL_DIR\data\pipes" -Recurse -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Force -Path "$INSTALL_DIR\bin" | Out-Null
New-Item -ItemType Directory -Force -Path "$INSTALL_DIR\data" | Out-Null
New-Item -ItemType Directory -Force -Path "$INSTALL_DIR\logic" | Out-Null
New-Item -ItemType Directory -Force -Path "$WEB_ROOT" | Out-Null

if (!(Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Python is not installed." -ForegroundColor Red
    Start-Sleep -Seconds 5
    Exit
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " STEP 2: INSTALLING WEBSOCKETD" -ForegroundColor Cyan
Write-Host "=========================================="

$ws_exe = "$INSTALL_DIR\bin\websocketd.exe"
if (!(Test-Path $ws_exe)) {
    Write-Host "   [..] Downloading websocketd..."
    $zip_path = "$env:TEMP\websocketd.zip"
    try {
        Invoke-WebRequest -Uri $WEBSOCKETD_URL -OutFile $zip_path
        Expand-Archive -Path $zip_path -DestinationPath "$INSTALL_DIR\bin" -Force
        Remove-Item $zip_path
    } catch {
        Write-Host "   [ERROR] Download failed." -ForegroundColor Red
    }
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " STEP 3: INITIALIZING DATABASE" -ForegroundColor Cyan
Write-Host "=========================================="
$init_db_script = @'
import sqlite3
import os

try:
    db_path = r'C:\Wardle\data\wardle.db'
    conn = sqlite3.connect(db_path)
    c = conn.cursor()

    c.execute('''CREATE TABLE IF NOT EXISTS match_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
        winner TEXT,
        target_word TEXT,
        score_blue INTEGER,
        score_red INTEGER
    )''')

    c.execute('''CREATE TABLE IF NOT EXISTS leaderboard (
        name TEXT PRIMARY KEY,
        wins INTEGER DEFAULT 1
    )''')

    print("   [..] Seeding leaderboard...")
    c.execute("INSERT OR IGNORE INTO leaderboard (name, wins) VALUES ('GERALT', 10)")
    c.execute("INSERT OR IGNORE INTO leaderboard (name, wins) VALUES ('YEN', 5)")
    c.execute("INSERT OR IGNORE INTO leaderboard (name, wins) VALUES ('CIRILLA', 2)")

    conn.commit()
    conn.close()
    print("   [OK] Database initialized.")
except Exception as e:
    print("   [ERROR] Database init failed: " + str(e))
'@
$init_db_script | Out-File -FilePath "$INSTALL_DIR\init_db.py" -Encoding UTF8
python "$INSTALL_DIR\init_db.py"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " STEP 4: BUILDING GAME FILES" -ForegroundColor Cyan
Write-Host "=========================================="

try {
    $words = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/dwyl/english-words/master/words_alpha.txt" -UseBasicParsing
    $filtered_words = $words.Content -split "`n" | Where-Object { $_.Trim().Length -eq 5 } | ForEach-Object { $_.Trim().ToUpper() }
    $filtered_words | Out-File "$INSTALL_DIR\logic\dictionary.txt" -Encoding UTF8
} catch {
    "APPLE`nBEACH`nCHAIR`nDANCE`nEAGLE" | Out-File "$INSTALL_DIR\logic\dictionary.txt" -Encoding UTF8
}

$wardle_py = @'
import sys
import json
import random
import sqlite3
import time
import os
import threading

INSTALL_DIR = r'C:\Wardle'
DB_PATH = r'C:\Wardle\data\wardle.db'
PIPE_DIR = os.path.join(INSTALL_DIR, 'data', 'pipes')
BROADCAST_FILE = os.path.join(PIPE_DIR, 'broadcast.log')

def log_broadcast(data):
    try:
        with open(BROADCAST_FILE, 'a') as f:
            f.write(json.dumps(data) + '\n')
    except: pass

def send_json(data):
    print(json.dumps(data), flush=True)

def get_word_list():
    try:
        with open(os.path.join(INSTALL_DIR, 'logic', 'dictionary.txt'), 'r') as f:
            return [w.strip() for w in f.readlines()]
    except:
        return ["APPLE", "BEACH", "CHAIR", "DANCE", "EAGLE"]

def check_word(target, guess):
    if len(guess) != 5: return "INVALID"
    if guess not in get_word_list(): return "INVALID"
    output = ['0'] * 5
    target_pool = list(target)
    guess_arr = list(guess)
    for i in range(5):
        if guess_arr[i] == target[i]:
            output[i] = '2'; target_pool[i] = None; guess_arr[i] = None
    for i in range(5):
        if guess_arr[i] is None: continue
        if guess_arr[i] in target_pool:
            output[i] = '1'; target_pool[target_pool.index(guess_arr[i])] = None
    return "".join(output)

def save_history(player_id, word):
    hist_file = os.path.join(PIPE_DIR, f'history_p{player_id}.json')
    try:
        if os.path.exists(hist_file):
            with open(hist_file, 'r') as f: h = json.load(f)
        else: h = []
        h.append(word)
        with open(hist_file, 'w') as f: json.dump(h, f)
    except: pass

def get_full_history():
    h = {}
    for pid in ['1', '2']:
        try:
            with open(os.path.join(PIPE_DIR, f'history_p{pid}.json'), 'r') as f: h[pid] = json.load(f)
        except: h[pid] = []
    return h

def clear_history():
    for pid in ['1', '2']:
        try: os.remove(os.path.join(PIPE_DIR, f'history_p{pid}.json'))
        except: pass

if not os.path.exists(PIPE_DIR):
    os.makedirs(PIPE_DIR, exist_ok=True)
    with open(BROADCAST_FILE, 'w') as f: f.write('')

def tail_f():
    try:
        file = open(BROADCAST_FILE, 'r')
        file.seek(0, 2) 
        while True:
            line = file.readline()
            if not line:
                time.sleep(0.1)
                continue
            print(line.strip(), flush=True)
    except: pass

t = threading.Thread(target=tail_f, daemon=True)
t.start()

my_id = None
lock1 = os.path.join(PIPE_DIR, 'p1.lock')
lock2 = os.path.join(PIPE_DIR, 'p2.lock')

if not os.path.exists(lock1):
    try:
        with open(lock1, 'w') as f: f.write('locked')
        my_id = 1
        with open(BROADCAST_FILE, 'w') as f: f.write('') 
        clear_history()
        current_word = random.choice(get_word_list())
        print(f" [DEBUG] SECRET WORD: {current_word}", file=sys.stderr, flush=True)
        with open(os.path.join(PIPE_DIR, 'current_word'), 'w') as f: f.write(current_word)
        with open(os.path.join(PIPE_DIR, 'scores.json'), 'w') as f: f.write(json.dumps({"1": 0, "2": 0}))
        try: os.remove(os.path.join(PIPE_DIR, 'done_p1')); os.remove(os.path.join(PIPE_DIR, 'done_p2'))
        except: pass
    except: pass
elif not os.path.exists(lock2):
    try:
        with open(lock2, 'w') as f: f.write('locked')
        my_id = 2
        log_broadcast({"type": "new_match_start", "scores": {"1": 0, "2": 0}})
    except: pass
else:
    send_json({"type": "full"})
    sys.exit(0)

try:
    with open(os.path.join(PIPE_DIR, 'scores.json'), 'r') as f: scores = json.load(f)
except:
    scores = {"1": 0, "2": 0}

send_json({"type": "welcome", "id": my_id, "scores": scores})

try:
    for line in sys.stdin:
        if not line: break
        try: req = json.loads(line)
        except: continue

        if req['action'] == 'guess':
            guess = req['word'].upper()
            row = req['rowIndex']
            try:
                with open(os.path.join(PIPE_DIR, 'current_word'), 'r') as f: target = f.read().strip()
            except: target = "ERROR"
            
            pattern = check_word(target, guess)
            
            if pattern == "INVALID":
                send_json({"type": "result", "pattern": "INVALID"})
                continue

            save_history(my_id, guess)
            send_json({"type": "result", "pattern": pattern, "guess": guess, "row": row})
            log_broadcast({"type": "opponent_move_proxy", "player": my_id, "pattern": pattern, "row": row})

            if pattern == "22222":
                try: os.remove(os.path.join(PIPE_DIR, 'done_p1')); os.remove(os.path.join(PIPE_DIR, 'done_p2'))
                except: pass

                with open(os.path.join(PIPE_DIR, 'scores.json'), 'r+') as f:
                    s = json.load(f)
                    s[str(my_id)] += 1
                    f.seek(0); f.write(json.dumps(s)); f.truncate()
                
                hist = get_full_history()
                if s[str(my_id)] >= 2:
                    try:
                        conn = sqlite3.connect(DB_PATH)
                        c = conn.cursor()
                        winner_name = "BLUE" if my_id == 1 else "RED"
                        c.execute("INSERT INTO match_history (winner, target_word, score_blue, score_red) VALUES (?, ?, ?, ?)", (winner_name, target, s['1'], s['2']))
                        conn.commit(); conn.close()
                    except: pass
                    send_json({"type": "ask_name"})
                    log_broadcast({"type": "wait_for_leaderboard_proxy", "winner_id": my_id, "history": hist})
                else:
                    winner_name = "BLUE" if my_id == 1 else "RED"
                    log_broadcast({"type": "round_over", "msg": f"{winner_name} WINS! Word: {target}", "scores": s, "history": hist})
            
            elif row == 4:
                open(os.path.join(PIPE_DIR, f'done_p{my_id}'), 'w').close()
                enemy_id = 2 if my_id == 1 else 1
                if os.path.exists(os.path.join(PIPE_DIR, f'done_p{enemy_id}')):
                    try: os.remove(os.path.join(PIPE_DIR, 'done_p1')); os.remove(os.path.join(PIPE_DIR, 'done_p2'))
                    except: pass
                    hist = get_full_history()
                    with open(os.path.join(PIPE_DIR, 'scores.json'), 'r') as f: s = json.load(f)
                    log_broadcast({"type": "round_over", "msg": f"DRAW! Word: {target}", "scores": s, "history": hist})
                else:
                    send_json({"type": "status", "msg": "Out of moves! Waiting for opponent..."})

        elif req['action'] == 'ready':
            open(os.path.join(PIPE_DIR, f'ready_p{my_id}'), 'w').close()
            if os.path.exists(os.path.join(PIPE_DIR, 'ready_p1')) and os.path.exists(os.path.join(PIPE_DIR, 'ready_p2')):
                try: 
                    for f in ['ready_p1', 'ready_p2', 'done_p1', 'done_p2']:
                        os.remove(os.path.join(PIPE_DIR, f))
                except: pass
                
                clear_history()
                new_word = random.choice(get_word_list())
                print(f" [DEBUG] NEW ROUND WORD: {new_word}", file=sys.stderr, flush=True)
                with open(os.path.join(PIPE_DIR, 'current_word'), 'w') as f: f.write(new_word)
                with open(os.path.join(PIPE_DIR, 'scores.json'), 'r') as f: s = json.load(f)
                log_broadcast({"type": "new_round", "scores": s})
            else:
                p1_r = os.path.exists(os.path.join(PIPE_DIR, 'ready_p1'))
                p2_r = os.path.exists(os.path.join(PIPE_DIR, 'ready_p2'))
                log_broadcast({"type": "ready_update", "p1_ready": p1_r, "p2_ready": p2_r})

        elif req['action'] == 'reset_request':
            log_broadcast({"type": "reset_flash"})
            open(os.path.join(PIPE_DIR, f'reset_p{my_id}'), 'w').close()
            if os.path.exists(os.path.join(PIPE_DIR, 'reset_p1')) and os.path.exists(os.path.join(PIPE_DIR, 'reset_p2')):
                try: 
                    for f in ['reset_p1', 'reset_p2', 'done_p1', 'done_p2']:
                        os.remove(os.path.join(PIPE_DIR, f))
                except: pass
                clear_history()
                with open(os.path.join(PIPE_DIR, 'scores.json'), 'w') as f: f.write(json.dumps({"1": 0, "2": 0}))
                new_word = random.choice(get_word_list())
                print(f" [DEBUG] RESET WORD: {new_word}", file=sys.stderr, flush=True)
                with open(os.path.join(PIPE_DIR, 'current_word'), 'w') as f: f.write(new_word)
                log_broadcast({"type": "new_match_start", "scores": {"1": 0, "2": 0}})

        elif req['action'] == 'submit_win':
            name = req['name'][:10]
            try:
                conn = sqlite3.connect(DB_PATH)
                c = conn.cursor()
                c.execute("INSERT INTO leaderboard (name, wins) VALUES (?, 1) ON CONFLICT(name) DO UPDATE SET wins = wins + 1", (name,))
                conn.commit()
                c.execute("SELECT name, wins FROM leaderboard ORDER BY wins DESC LIMIT 10")
                lb_data = [{"name": r[0], "wins": r[1]} for r in c.fetchall()]
                conn.close()
                log_broadcast({"type": "show_leaderboard", "data": lb_data, "winner": name})
            except: pass
            
        elif req['action'] == 'rematch_request':
            open(os.path.join(PIPE_DIR, f'rematch_p{my_id}'), 'w').close()
            if os.path.exists(os.path.join(PIPE_DIR, 'rematch_p1')) and os.path.exists(os.path.join(PIPE_DIR, 'rematch_p2')):
                try: 
                    for f in ['rematch_p1', 'rematch_p2', 'done_p1', 'done_p2']:
                        os.remove(os.path.join(PIPE_DIR, f))
                except: pass
                with open(os.path.join(PIPE_DIR, 'scores.json'), 'w') as f: f.write(json.dumps({"1": 0, "2": 0}))
                new_word = random.choice(get_word_list())
                with open(os.path.join(PIPE_DIR, 'current_word'), 'w') as f: f.write(new_word)
                clear_history()
                log_broadcast({"type": "new_match_start", "scores": {"1": 0, "2": 0}})
            else:
                count = 0
                if os.path.exists(os.path.join(PIPE_DIR, 'rematch_p1')): count += 1
                if os.path.exists(os.path.join(PIPE_DIR, 'rematch_p2')): count += 1
                log_broadcast({"type": "rematch_update", "count": count})

        elif req['action'] == 'claim_forfeit':
             winner_name = "BLUE" if my_id == 1 else "RED"
             send_json({"type": "ask_name"})
             log_broadcast({"type": "wait_for_leaderboard_proxy", "winner_id": my_id, "msg": "Opponent disconnected. You win!"})

except Exception as e: pass
finally:
    try:
        os.remove(os.path.join(PIPE_DIR, f'p{my_id}.lock'))
        log_broadcast({"type": "opponent_disconnected", "leaver": my_id})
    except: pass
'@

$wardle_py | Out-File -FilePath "$INSTALL_DIR\wardle_game.py" -Encoding UTF8

$html_content = @'
<!DOCTYPE html>
<html>
<head>
    <title>WARDLE</title>
    <style>
        * { box-sizing: border-box; } 
        body { font-family: 'Courier New', monospace; text-align: center; background: #121213; color: white; display: flex; flex-direction: column; align-items: center; min-height: 100vh; margin: 0; padding: 10px; }
        h1 { margin: 5px 0 10px 0; font-size: 40px; letter-spacing: 5px; text-shadow: 0 0 10px #333; }
        #top-hud { display: flex; flex-direction: column; align-items: center; width: 100%; margin-bottom: 20px; }
        #status { height: 25px; margin-bottom: 5px; color: yellow; font-size: 18px; font-weight: bold; }
        #scoreboard { display: flex; gap: 30px; justify-content: center; }
        .score-box { padding: 8px 20px; border: 2px solid #333; border-radius: 8px; font-size: 20px; font-weight: bold; background: #1a1a1b; min-width: 100px; box-shadow: 0 4px 6px rgba(0,0,0,0.3); }
        .p1-score { color: #4fa3ff; border-color: #4fa3ff; }
        .p2-score { color: #ff5e5e; border-color: #ff5e5e; }
        #game-area { display: flex; align-items: flex-start; justify-content: center; gap: 60px; width: 100%; max-width: 1600px; }
        .panel { display: flex; flex-direction: column; align-items: center; flex: 0 0 332px; width: 332px; min-width: 332px; margin: 0; padding: 0; }
        h3 { margin: 0 0 15px 0; padding: 0; background: #222; border-radius: 4px; width: 100%; height: 45px; font-size: 22px; border: 1px solid #333; display: flex; align-items: center; justify-content: center; }
        #keyboard-template, #enemy-template { width: 100%; }
        .grid { display: grid; grid-template-columns: repeat(5, 1fr); gap: 8px; width: 100%; }
        .box { width: 60px; height: 60px; border: 2px solid #3a3a3c; font-size: 36px; font-weight: bold; display: flex; align-items: center; justify-content: center; text-transform: uppercase; background: #121213; }
        .input-group { display: grid; grid-template-columns: repeat(5, 1fr); gap: 8px; width: 100%; margin-top: 15px; }
        .input-box { width: 60px; height: 60px; background: transparent; border: 2px solid #555; color: white; font-size: 36px; text-align: center; text-transform: uppercase; font-weight: bold; font-family: 'Courier New', monospace; padding: 0; margin: 0; border-radius: 0; }
        .input-box:focus { border-color: white; outline: none; }
        .input-box:disabled { opacity: 0.3; border-color: #222; }
        #keyboard-container { display: grid; grid-template-columns: repeat(6, 1fr); gap: 6px; width: 100%; }
        .key { width: 100%; height: 50px; background: #818384; color: white; border: none; border-radius: 4px; font-weight: bold; font-size: 20px; cursor: pointer; }
        .key.green { background-color: #538d4e; }
        .key.yellow { background-color: #b59f3b; }
        .key.gray { background-color: #3a3a3c; color: #555; cursor: not-allowed; opacity: 0.5; }
        #next-round-btn { margin-top: 15px; padding: 15px 0; width: 100%; font-size: 20px; font-weight: bold; background-color: #3a3a3c; color: #888; border: 2px solid #555; border-radius: 8px; cursor: not-allowed; display: none; }
        #next-round-btn.active { cursor: pointer; color: white; border-color: white; }
        #next-round-btn.ready { background-color: #538d4e; border-color: #538d4e; color: white; }
        #reset-btn { margin-top: 10px; padding: 10px 0; width: 100%; font-size: 14px; font-weight: bold; background-color: #222; color: #555; border: 1px solid #333; border-radius: 6px; cursor: pointer; letter-spacing: 1px; }
        #reset-btn:hover { background-color: #333; color: white; }
        #reset-btn.pending { background-color: #b59f3b; color: white; border-color: #b59f3b; }
        @keyframes flash-red { 0% { background-color: #222; border-color: #333; } 50% { background-color: #a00; border-color: red; color: white; } 100% { background-color: #222; border-color: #333; } }
        #reset-btn.flash { animation: flash-red 1s infinite; }
        .overlay { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(18, 18, 19, 0.98); z-index: 999; flex-direction: column; justify-content: center; align-items: center; }
        #leaderboard-table { border-collapse: collapse; width: 400px; margin-bottom: 30px; }
        #leaderboard-table th { background: #333; padding: 15px; font-size: 24px; text-align: left; }
        #leaderboard-table td { background: #1a1a1b; padding: 12px; font-size: 20px; border-bottom: 1px solid #333; }
        #leaderboard-table td:nth-child(2) { text-align: right; color: yellow; }
        #new-match-btn { padding: 20px 60px; font-size: 28px; font-weight: bold; background: #538d4e; color: white; border: none; border-radius: 10px; cursor: pointer; }
        #name-input { font-size: 32px; padding: 10px; text-align: center; text-transform: uppercase; background: #111; color: white; border: 2px solid white; margin-bottom: 20px; }
        #submit-name-btn { padding: 10px 30px; font-size: 24px; background: white; color: black; border: none; cursor: pointer; }
        .green { background-color: #538d4e; border-color: #538d4e; }
        .yellow { background-color: #b59f3b; border-color: #b59f3b; }
        .gray { background-color: #3a3a3c; border-color: #3a3a3c; }
        #full-screen h1 { color: red !important; font-size: 80px !important; margin: 0; }
        
        #footer { margin-top: 50px; display: flex; flex-direction: column; align-items: center; gap: 10px; opacity: 0.6; }
        #footer svg { width: 50px; height: 50px; fill: white; }
        #footer span { font-size: 14px; letter-spacing: 2px; color: #888; }
    </style>
</head>
<body>
    <div id="full-screen" class="overlay"><h1>ARENA OCCUPIED</h1></div>
    <div id="name-overlay" class="overlay"><h1 id="win-title">YOU WON THE MATCH!</h1><p>Enter your name for the Hall of Fame:</p><input id="name-input" maxlength="8" placeholder="NAME"><button id="submit-name-btn" onclick="submitName()">SUBMIT</button></div>
    <div id="wait-overlay" class="overlay"><h1>MATCH OVER</h1><p id="wait-message">Waiting for the winner to sign the leaderboard...</p></div>
    <div id="leaderboard-overlay" class="overlay"><h1>LEADERBOARD</h1><table id="leaderboard-table"><thead><tr><th>PLAYER</th><th>WINS</th></tr></thead><tbody id="lb-body"></tbody></table><p id="rematch-status" style="color: #888; margin-bottom: 10px;">Waiting for players...</p><button id="new-match-btn" onclick="requestRematch()">START NEW MATCH</button></div>
    
    <div id="main-app">
        <h1>WARDLE</h1>
        <div id="top-hud">
            <div id="status">Connecting...</div>
            <div id="scoreboard"><div id="score-p1" class="score-box p1-score">BLUE: 0</div><div id="score-p2" class="score-box p2-score">RED: 0</div></div>
        </div>
        <div id="game-area">
            <div id="slot-left" class="panel"></div>
            <div id="slot-center" class="panel">
                <h3>YOUR BOARD</h3><div id="my-grid" class="grid"></div>
                <div class="input-group"><input class="input-box" maxlength="1" autofocus><input class="input-box" maxlength="1"><input class="input-box" maxlength="1"><input class="input-box" maxlength="1"><input class="input-box" maxlength="1"></div>
                <button id="next-round-btn" onclick="sendReady()">NEXT ROUND</button><button id="reset-btn" onclick="sendReset()">RESET MATCH</button>
            </div>
            <div id="slot-right" class="panel"></div>
        </div>
        
        <div id="footer">
            <svg version="1.0" xmlns="http://www.w3.org/2000/svg" width="293.000000pt" height="280.000000pt" viewBox="0 0 293.000000 280.000000" preserveAspectRatio="xMidYMid meet">
                <g transform="translate(0.000000,280.000000) scale(0.100000,-0.100000)" stroke="none">
                    <path d="M1185 2785 c-288 -54 -531 -176 -732 -368 -122 -117 -209 -233 -282 -377 -109 -213 -154 -401 -154 -640 0 -239 45 -427 154 -640 193 -378 540 -642 970 -736 119 -27 427 -27 549 -1 570 122 987 542 1107 1117 25 119 25 401 0 520 -81 388 -292 702 -611 912 -147 96 -308 164 -486 203 -107 24 -409 29 -515 10z m475 -71 c259 -45 503 -175 700 -373 258 -259 390 -577 390 -942 0 -562 -344 -1054 -878 -1255 -166 -63 -392 -92 -570 -75 -677 68 -1186 599 -1219 1271 -28 583 336 1123 887 1318 225 79 452 97 690 56z"/>
                    <path d="M1258 2135 c-190 -36 -332 -109 -458 -235 -96 -96 -149 -179 -187 -295 -23 -69 -26 -97 -26 -205 0 -107 3 -136 25 -203 74 -223 262 -410 495 -492 339 -118 708 -36 944 211 79 84 128 163 166 269 25 72 28 93 28 215 0 122 -3 143 -28 215 -69 197 -216 354 -420 451 -153 72 -374 100 -539 69z m362 -36 c47 -11 128 -40 180 -66 79 -38 109 -60 176 -127 111 -112 154 -213 154 -361 0 -145 -49 -254 -165 -370 -65 -65 -100 -91 -183 -134 -283 -145 -590 -143 -879 7 -70 36 -185 113 -179 120 2 1 33 -15 68 -38 135 -84 309 -130 497 -130 253 0 435 66 582 211 76 76 130 174 150 277 45 233 -108 440 -391 527 -73 22 -258 31 -346 16 -99 -17 -239 -87 -309 -155 -150 -147 -155 -333 -12 -462 77 -69 154 -104 258 -117 238 -30 439 80 439 241 0 112 -102 204 -226 205 -33 0 -60 -7 -79 -19 l-29 -19 56 -6 c72 -8 118 -35 141 -82 74 -149 -167 -276 -349 -184 -151 77 -180 244 -62 353 84 78 180 108 319 102 85 -4 106 -9 173 -41 138 -65 226 -181 226 -298 0 -152 -160 -307 -367 -355 -84 -19 -230 -19 -308 1 -276 71 -449 280 -414 499 18 107 76 198 174 273 193 146 441 192 705 132z"/>
                </g>
            </svg>
            <span>&copy; 2026 SEBINY LABS</span>
        </div>
    </div>

    <div style="display:none;"><div id="keyboard-template"><h3>KEYBOARD</h3><div id="keyboard-container"></div></div><div id="enemy-template"><h3>ENEMY</h3><div id="op-grid" class="grid"></div></div></div>
    
    <script>
        const socket = new WebSocket('ws://' + window.location.hostname + ':8765');
        const inputs = document.querySelectorAll('.input-box');
        const btn = document.getElementById('next-round-btn');
        const resetBtn = document.getElementById('reset-btn');
        const lbOverlay = document.getElementById('leaderboard-overlay');
        const nameOverlay = document.getElementById('name-overlay');
        const waitOverlay = document.getElementById('wait-overlay');
        const newMatchBtn = document.getElementById('new-match-btn');
        let myPlayerId = 0;
        let currentRow = 0;
        let gameActive = false;

        function createGrid(id) {
            const grid = document.getElementById(id);
            grid.innerHTML = "";
            for(let i=0; i<25; i++) {
                let box = document.createElement('div');
                box.className = 'box';
                box.id = `${id}-box-${i}`;
                grid.appendChild(box);
            }
        }
        createGrid('my-grid');
        createGrid('op-grid');

        const kbContainer = document.getElementById('keyboard-container');
        const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        for (let char of alphabet) {
            let btn = document.createElement('button');
            btn.innerText = char;
            btn.className = 'key';
            btn.id = 'key-' + char;
            btn.onclick = () => handleVirtualKey(char);
            kbContainer.appendChild(btn);
        }

        function setupLayout(playerId) {
            const left = document.getElementById('slot-left');
            const right = document.getElementById('slot-right');
            const kb = document.getElementById('keyboard-template');
            const enemy = document.getElementById('enemy-template');
            left.innerHTML = ""; right.innerHTML = "";
            if (playerId === 1) {
                left.appendChild(kb); right.appendChild(enemy);
                document.getElementById('score-p1').style.textDecoration = "underline";
            } else {
                left.appendChild(enemy); right.appendChild(kb);
                document.getElementById('score-p2').style.textDecoration = "underline";
            }
        }

        function setInputsDisabled(disabled) {
            inputs.forEach(input => {
                input.disabled = disabled;
                if(disabled) input.value = "";
            });
            if(!disabled) inputs[0].focus();
        }

        function handleVirtualKey(char) {
            if (!gameActive) return;
            for (let input of inputs) {
                if (input.value === "") {
                    input.value = char;
                    input.dispatchEvent(new Event('input'));
                    break;
                }
            }
        }

        function submitName() {
            const name = document.getElementById('name-input').value.toUpperCase();
            if(name.length > 0) {
                socket.send(JSON.stringify({action: 'submit_win', name: name}));
                nameOverlay.style.display = 'none';
            }
        }

        function requestRematch() {
            socket.send(JSON.stringify({action: 'rematch_request'}));
            newMatchBtn.disabled = true;
            newMatchBtn.innerText = "WAITING...";
            document.getElementById('rematch-status').innerText = "Waiting for other player...";
        }

        function sendReady() {
            socket.send(JSON.stringify({action: 'ready'}));
            btn.classList.add('ready'); 
            btn.innerText = "WAITING FOR OPPONENT...";
        }

        function sendReset() {
            socket.send(JSON.stringify({action: 'reset_request'}));
            resetBtn.innerText = "WAITING FOR OPPONENT...";
            resetBtn.classList.add('pending'); 
        }

        function revealEnemyHistory(history) {
            const enemyId = (myPlayerId === 1) ? "2" : "1";
            const enemyWords = history[enemyId];
            if (enemyWords) {
                enemyWords.forEach((word, index) => {
                    let startIndex = index * 5;
                    for (let i = 0; i < 5; i++) {
                        let box = document.getElementById(`op-grid-box-${startIndex + i}`);
                        box.innerText = word[i]; 
                    }
                });
            }
        }

        function renderLeaderboard(data) {
            const tbody = document.getElementById('lb-body');
            tbody.innerHTML = "";
            data.forEach(row => {
                let tr = document.createElement('tr');
                tr.innerHTML = `<td>${row.name}</td><td>${row.wins}</td>`;
                tbody.appendChild(tr);
            });
        }

        socket.onmessage = (event) => {
            const data = JSON.parse(event.data);

            if (data.type === 'full') {
                document.getElementById('main-app').style.display = 'none';
                document.getElementById('full-screen').style.display = 'flex';
            }
            else if (data.type === 'welcome') {
                myPlayerId = data.id;
                setupLayout(data.id);
                updateScores(data.scores);
                document.getElementById('status').innerText = "Waiting for Opponent...";
                setInputsDisabled(true); 
            }
            else if (data.type === 'opponent_disconnected') {
                if (data.leaver !== myPlayerId) {
                    document.getElementById('status').innerText = "OPPONENT LEFT!";
                    socket.send(JSON.stringify({action: 'claim_forfeit'}));
                }
            }
            else if (data.type === 'new_match_start') {
                lbOverlay.style.display = 'none';
                nameOverlay.style.display = 'none';
                waitOverlay.style.display = 'none';
                newMatchBtn.disabled = false;
                newMatchBtn.innerText = "START NEW MATCH";
                document.getElementById('rematch-status').innerText = "Waiting for players...";
                resetBoard();
                updateScores(data.scores);
                document.getElementById('status').innerText = "MATCH START!";
                gameActive = true;
                setInputsDisabled(false); 
                btn.style.display = "none";
                resetBtn.classList.remove('flash', 'pending');
                resetBtn.innerText = "RESET MATCH"; 
            }
            else if (data.type === 'new_round') {
                resetBoard();
                updateScores(data.scores);
                document.getElementById('status').innerText = "ROUND START!";
                gameActive = true;
                setInputsDisabled(false); 
                btn.style.display = "none";
                btn.className = "";
                btn.innerText = "NEXT ROUND";
                resetBtn.classList.remove('flash', 'pending');
                resetBtn.innerText = "RESET MATCH"; 
            }
            else if (data.type === 'reset_flash') {
                resetBtn.classList.add('flash');
            }
            else if (data.type === 'ready_update') {
               if ((myPlayerId === 1 && data.p1_ready) || (myPlayerId === 2 && data.p2_ready)) {
                   btn.innerText = "WAITING FOR OPPONENT...";
               }
            }
            else if (data.type === 'rematch_update') {
                if (data.count === 1) document.getElementById('rematch-status').innerText = "1/2 Players Ready";
            }
            else if (data.type === 'result') {
                if (data.pattern === "INVALID") alert("Not in word list!");
                else {
                    fillRow('my-grid', data.row, data.guess, data.pattern);
                    updateKeyboard(data.guess, data.pattern); 
                    clearInputs();
                    currentRow++;
                    if (currentRow >= 5) {
                        gameActive = false;
                        setInputsDisabled(true); 
                    }
                }
            }
            else if (data.type === 'opponent_move_proxy') {
                if (data.player !== myPlayerId) {
                    fillRow('op-grid', data.row, "?????", data.pattern);
                }
            }
            else if (data.type === 'round_over' || data.type === 'game_over') {
                document.getElementById('status').innerText = data.msg;
                gameActive = false;
                setInputsDisabled(true); 
                if (data.history) revealEnemyHistory(data.history);
                btn.style.display = "block";
                btn.classList.add('active'); 
            }
            else if (data.type === 'status') {
                document.getElementById('status').innerText = data.msg;
            }
            else if (data.type === 'ask_name') {
                gameActive = false;
                setInputsDisabled(true);
                document.getElementById('win-title').innerText = "YOU WON THE MATCH!";
                setTimeout(() => { nameOverlay.style.display = 'flex'; }, 1000);
            }
            else if (data.type === 'wait_for_leaderboard') {
                gameActive = false;
                setInputsDisabled(true);
                setTimeout(() => { waitOverlay.style.display = 'flex'; }, 1000);
            }
            else if (data.type === 'wait_for_leaderboard_proxy') {
                if (data.winner_id !== myPlayerId) {
                    gameActive = false;
                    setInputsDisabled(true);
                    if (data.history) revealEnemyHistory(data.history); 
                    if (data.msg) document.getElementById('wait-message').innerText = data.msg;
                    else document.getElementById('wait-message').innerText = "Waiting for the winner to sign the leaderboard...";
                    setTimeout(() => { waitOverlay.style.display = 'flex'; }, 1000);
                }
            }
            else if (data.type === 'show_leaderboard') {
                nameOverlay.style.display = 'none';
                waitOverlay.style.display = 'none';
                renderLeaderboard(data.data);
                lbOverlay.style.display = 'flex';
            }
        };

        function updateKeyboard(word, pattern) {
            for (let i = 0; i < 5; i++) {
                let char = word[i].toUpperCase();
                let colorCode = pattern[i]; 
                let keyBtn = document.getElementById('key-' + char);
                if (!keyBtn) continue;
                if (colorCode === '2') keyBtn.className = 'key green';
                else if (colorCode === '1' && !keyBtn.classList.contains('green')) keyBtn.className = 'key yellow';
                else if (colorCode === '0' && !keyBtn.classList.contains('green') && !keyBtn.classList.contains('yellow')) {
                    keyBtn.className = 'key gray'; keyBtn.disabled = true;
                }
            }
        }

        function fillRow(gridId, rowNum, word, pattern) {
            let startIndex = rowNum * 5;
            for (let i = 0; i < 5; i++) {
                let box = document.getElementById(`${gridId}-box-${startIndex + i}`);
                if(word !== "?????") box.innerText = word[i];
                box.className = 'box'; 
                if (pattern[i] === '2') box.classList.add('green');
                else if (pattern[i] === '1') box.classList.add('yellow');
                else box.classList.add('gray');
            }
        }

        function resetBoard() {
            createGrid('my-grid'); createGrid('op-grid'); 
            document.querySelectorAll('.key').forEach(k => { k.className = 'key'; k.disabled = false; });
            currentRow = 0; clearInputs();
        }

        function updateScores(scores) {
            document.getElementById('score-p1').innerText = "BLUE: " + scores['1'];
            document.getElementById('score-p2').innerText = "RED: " + scores['2'];
        }

        function submitGuess() {
            if (!gameActive || currentRow >= 5) return;
            let word = "";
            inputs.forEach(input => word += input.value);
            if (word.length === 5) {
                socket.send(JSON.stringify({action: 'guess', word: word, rowIndex: currentRow}));
            }
        }

        function clearInputs() {
            inputs.forEach(input => input.value = '');
            if(gameActive) inputs[0].focus();
        }

        inputs.forEach((input, index) => {
            input.addEventListener('input', (e) => {
                if (e.target.value.length === 1 && index < 4) inputs[index + 1].focus();
            });
            input.addEventListener('keydown', (e) => {
                if (!gameActive) { e.preventDefault(); return; }
                if (e.key === 'Enter') submitGuess();
                if (e.key === 'Backspace' && e.target.value === '' && index > 0) inputs[index - 1].focus();
            });
        });
    </script>
</body>
</html>
'@

$html_content | Out-File -FilePath "$WEB_ROOT\index.html" -Encoding UTF8

# FIX: Added 'rmdir' command to the batch file. 
# This ensures that every time you click "Play Wardle", it deletes the old state files before starting.
$batch_content = @"
@echo off
title Wardle Launcher
cd /d "C:\Wardle"

echo Cleaning previous session data...
if exist "C:\Wardle\data\pipes" (
    rmdir /s /q "C:\Wardle\data\pipes"
)

echo Starting Game Engine...
start "Wardle Game Server" /MIN "C:\Wardle\bin\websocketd.exe" --port=8765 --address=127.0.0.1 python "C:\Wardle\wardle_game.py"
start "Wardle Web Host" /MIN python -m http.server 8000 --directory "C:\Wardle\www"

echo Launching Player 1...
timeout /t 2 >nul
start http://localhost:8000

echo Launching Player 2...
timeout /t 2 >nul
start http://localhost:8000

exit
"@

$desktop_path = [Environment]::GetFolderPath("Desktop")
$launcher_path = "$desktop_path\Play Wardle.bat"
$batch_content | Out-File -FilePath $launcher_path -Encoding ASCII

Write-Host "   [OK] Launcher created."
Write-Host "   [..] Launching the game (2 Windows)..."
Start-Sleep -Seconds 2
Start-Process $launcher_path

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host " INSTALLATION SUCCESSFUL!" -ForegroundColor Green
Write-Host "=========================================="
Start-Sleep -Seconds 5