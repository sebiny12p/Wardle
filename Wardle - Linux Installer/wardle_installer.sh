#!/bin/bash
# --- Wardle ---
# --- CONFIGURATION ---
INSTALL_DIR="/opt/wardle"
WEB_ROOT="/var/www/html"
DB_USER="wardle_user"
DB_PASS="secure_password"
DB_NAME="wardle_db"

# --- CHECK ROOT ---
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Please run as root (sudo bash wardle_installer.sh)"
  exit 1
fi

echo "=========================================="
echo " STEP 1: PREPARING ENVIRONMENT"
echo "=========================================="
apt-get update -qq
apt-get install -y apache2 mariadb-server jq curl wget unzip python3

systemctl enable --now apache2
systemctl enable --now mariadb

echo "=========================================="
echo " STEP 2: INSTALLING WEBSOCKETD"
echo "=========================================="
if ! command -v websocketd &> /dev/null; then
    wget -q https://github.com/joewalnes/websocketd/releases/download/v0.4.1/websocketd-0.4.1-linux_amd64.zip -O /tmp/websocketd.zip
    unzip -qo /tmp/websocketd.zip -d /tmp/
    mv /tmp/websocketd /usr/local/bin/
    chmod +x /usr/local/bin/websocketd
    rm /tmp/websocketd.zip
    echo "   [OK] Websocketd installed."
else
    echo "   [OK] Websocketd already present."
fi

echo "=========================================="
echo " STEP 3: INITIALIZING DATABASE"
echo "=========================================="
mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};"
mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

mysql -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" <<EOF
CREATE TABLE IF NOT EXISTS match_history (
    id INT AUTO_INCREMENT PRIMARY KEY,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    winner VARCHAR(10),
    target_word VARCHAR(5),
    score_blue INT,
    score_red INT
);
CREATE TABLE IF NOT EXISTS leaderboard (
    name VARCHAR(50) PRIMARY KEY,
    wins INT DEFAULT 1
);
INSERT IGNORE INTO leaderboard (name, wins) VALUES ('GERALT', 10);
INSERT IGNORE INTO leaderboard (name, wins) VALUES ('YEN', 5);
INSERT IGNORE INTO leaderboard (name, wins) VALUES ('CIRILLA', 2);
EOF
echo "   [OK] Database initialized & seeded."

echo "=========================================="
echo " STEP 4: BUILDING GAME FILES"
echo "=========================================="
mkdir -p "$INSTALL_DIR/logic"
chmod 755 "$INSTALL_DIR"

if [ ! -f "$INSTALL_DIR/logic/dictionary.txt" ]; then
    echo "   [..] Downloading word list..."
    curl -s -L https://raw.githubusercontent.com/dwyl/english-words/master/words_alpha.txt | grep -E '^.{5}$' | tr '[:lower:]' '[:upper:]' > "$INSTALL_DIR/logic/dictionary.txt"
fi

# --- Check Word Script ---
cat << 'EOF' > "$INSTALL_DIR/logic/check_word.sh"
#!/bin/bash
TARGET=$1
GUESS=$2

if ! grep -Fxq "$GUESS" /opt/wardle/logic/dictionary.txt; then
    echo "INVALID"
    exit
fi

output=(0 0 0 0 0)
target_pool="$TARGET"

for (( i=0; i<5; i++ )); do
    t_char="${TARGET:$i:1}"
    g_char="${GUESS:$i:1}"
    if [[ "$t_char" == "$g_char" ]]; then
        output[$i]=2
        target_pool="${target_pool:0:i}_${target_pool:i+1}"
    fi
done

for (( i=0; i<5; i++ )); do
    if [[ "${output[$i]}" == "2" ]]; then continue; fi
    g_char="${GUESS:$i:1}"
    if [[ "$target_pool" == *"$g_char"* ]]; then
        output[$i]=1
        target_pool="${target_pool/$g_char/_}"
    else
        output[$i]=0
    fi
done
echo "${output[*]}" | tr -d ' '
EOF
chmod +x "$INSTALL_DIR/logic/check_word.sh"

# --- Main Logic (Bash Port of Final Python Logic) ---
cat <<EOF > "$INSTALL_DIR/wardle.sh"
#!/bin/bash

# CONFIG
PIPE_DIR="/dev/shm/wardle_game"
BROADCAST_FILE="\$PIPE_DIR/broadcast.log"
DB_USER="${DB_USER}"
DB_PASS="${DB_PASS}"
DB_NAME="${DB_NAME}"

mkdir -p "\$PIPE_DIR"
touch "\$BROADCAST_FILE"

# --- HELPER FUNCTIONS ---
get_score() { cat "\$PIPE_DIR/score_p\$1" 2>/dev/null || echo 0; }
send_json() { echo "\$1"; }
broadcast_json() { echo "\$1" | tr -d '\n' >> "\$BROADCAST_FILE"; echo "" >> "\$BROADCAST_FILE"; }

pick_word() { 
    shuf -n 1 $INSTALL_DIR/logic/dictionary.txt > "\$PIPE_DIR/current_word"
    w=\$(cat "\$PIPE_DIR/current_word")
    echo " [DEBUG] SECRET WORD: \$w" >&2
}

reset_history() {
    echo "[]" > "\$PIPE_DIR/history_p1"
    echo "[]" > "\$PIPE_DIR/history_p2"
}

save_guess() {
    local player=\$1; local word=\$2; tmp=\$(mktemp)
    if [ ! -s "\$PIPE_DIR/history_p\$player" ]; then echo "[]" > "\$PIPE_DIR/history_p\$player"; fi
    jq -c --arg w "\$word" '. + [\$w]' "\$PIPE_DIR/history_p\$player" > "\$tmp" && mv "\$tmp" "\$PIPE_DIR/history_p\$player"
}

get_full_history() {
    if [ -s "\$PIPE_DIR/history_p1" ]; then h1=\$(cat "\$PIPE_DIR/history_p1"); else h1="[]"; fi
    if [ -s "\$PIPE_DIR/history_p2" ]; then h2=\$(cat "\$PIPE_DIR/history_p2"); else h2="[]"; fi
    jq -n -c --argjson p1 "\$h1" --argjson p2 "\$h2" '{ "1": \$p1, "2": \$p2 }'
}

clean_flags() {
    rm -f "\$PIPE_DIR/ready_p1" "\$PIPE_DIR/ready_p2"
    rm -f "\$PIPE_DIR/done_p1" "\$PIPE_DIR/done_p2"
    rm -f "\$PIPE_DIR/reset_p1" "\$PIPE_DIR/reset_p2"
    rm -f "\$PIPE_DIR/rematch_p1" "\$PIPE_DIR/rematch_p2"
}

# --- LISTENER ---
( tail -f -n 0 "\$BROADCAST_FILE" | while read -r line; do echo "\$line"; done ) &
LISTENER_PID=\$!

# --- HANDSHAKE ---
if mkdir "\$PIPE_DIR/p1_lock" 2>/dev/null; then
    MY_ID=1
    echo "" > "\$BROADCAST_FILE" 
    echo "0" > "\$PIPE_DIR/score_p1"; echo "0" > "\$PIPE_DIR/score_p2"
    clean_flags; reset_history; pick_word
elif mkdir "\$PIPE_DIR/p2_lock" 2>/dev/null; then
    MY_ID=2
    ( sleep 0.5; s1=\$(get_score 1); s2=\$(get_score 2)
      echo "{\"type\": \"new_match_start\", \"scores\": {\"1\": \$s1, \"2\": \$s2}}" >> "\$BROADCAST_FILE"
    ) &
else
    echo "{\"type\": \"full\"}"; kill "\$LISTENER_PID"; exit 0
fi

trap_disconnect() {
    rmdir "\$PIPE_DIR/p\${MY_ID}_lock" 2>/dev/null
    broadcast_json "{\"type\": \"opponent_disconnected\", \"leaver\": \$MY_ID}"
    kill "\$LISTENER_PID" 2>/dev/null
    exit 0
}
trap trap_disconnect EXIT

sleep 0.2
s1=\$(get_score 1); s2=\$(get_score 2)
send_json "{\"type\": \"welcome\", \"id\": \$MY_ID, \"scores\": {\"1\": \$s1, \"2\": \$s2}}"

# --- MAIN LOOP ---
while read -r line; do
    action=\$(echo "\$line" | jq -r '.action')

    case "\$action" in
        "guess")
            word=\$(echo "\$line" | jq -r '.word' | tr '[:upper:]' '[:lower:]')
            row=\$(echo "\$line" | jq -r '.rowIndex')
            target=\$(cat "\$PIPE_DIR/current_word")
            
            pattern=\$(/bin/bash $INSTALL_DIR/logic/check_word.sh "\$target" "\$word")
            
            # GUARD CLAUSE
            if [ "\$pattern" == "INVALID" ]; then
                send_json "{\"type\": \"result\", \"pattern\": \"INVALID\"}"
                continue
            fi

            save_guess "\$MY_ID" "\$word"
            send_json "{\"type\": \"result\", \"pattern\": \"\$pattern\", \"guess\": \"\$word\", \"row\": \$row}"
            broadcast_json "{\"type\": \"opponent_move_proxy\", \"player\": \$MY_ID, \"pattern\": \"\$pattern\", \"row\": \$row}"

            if [ "\$pattern" == "22222" ]; then
                rm -f "\$PIPE_DIR/done_p1" "\$PIPE_DIR/done_p2"
                current=\$(cat "\$PIPE_DIR/score_p\$MY_ID")
                new_score=\$((current + 1))
                echo "\$new_score" > "\$PIPE_DIR/score_p\$MY_ID"
                
                hist=\$(get_full_history)
                if [ "\$new_score" -ge 2 ]; then
                    winner_name=\$([ "\$MY_ID" -eq 1 ] && echo "BLUE" || echo "RED")
                    s1=\$(get_score 1); s2=\$(get_score 2)
                    mariadb -u"\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" -e "INSERT INTO match_history (winner, target_word, score_blue, score_red) VALUES ('\$winner_name', '\$target', \$s1, \$s2);"
                    send_json "{\"type\": \"ask_name\"}"
                    msg=\$(jq -n -c --arg win "\$MY_ID" --argjson h "\$hist" '{"type": "wait_for_leaderboard_proxy", "winner_id": (\$win|tonumber), "history": \$h}')
                    broadcast_json "\$msg"
                else
                    s1=\$(get_score 1); s2=\$(get_score 2)
                    winner_name=\$([ "\$MY_ID" -eq 1 ] && echo "BLUE" || echo "RED")
                    target_upper=\${target^^}
                    msg=\$(jq -n -c --arg msg "\$winner_name WINS! Word: \$target_upper" --argjson h "\$hist" --arg s1 "\$s1" --arg s2 "\$s2" '{"type": "round_over", "msg": \$msg, "scores": {"1": (\$s1|tonumber), "2": (\$s2|tonumber)}, "history": \$h}')
                    broadcast_json "\$msg"
                fi
            elif [ "\$row" -eq 4 ]; then
                 # DRAW LOGIC
                 touch "\$PIPE_DIR/done_p\$MY_ID"
                 enemy_id=\$([ "\$MY_ID" -eq 1 ] && echo 2 || echo 1)
                 if [ -f "\$PIPE_DIR/done_p\$enemy_id" ]; then
                     rm -f "\$PIPE_DIR/done_p1" "\$PIPE_DIR/done_p2"
                     hist=\$(get_full_history)
                     s1=\$(get_score 1); s2=\$(get_score 2)
                     target_upper=\${target^^}
                     msg=\$(jq -n -c --arg msg "DRAW! Word: \$target_upper" --argjson h "\$hist" --arg s1 "\$s1" --arg s2 "\$s2" '{"type": "round_over", "msg": \$msg, "scores": {"1": (\$s1|tonumber), "2": (\$s2|tonumber)}, "history": \$h}')
                     broadcast_json "\$msg"
                 else
                     send_json "{\"type\": \"status\", \"msg\": \"Out of moves! Waiting...\"}"
                 fi
            fi
            ;;

        "ready")
            touch "\$PIPE_DIR/ready_p\$MY_ID"
            if [ -f "\$PIPE_DIR/ready_p1" ] && [ -f "\$PIPE_DIR/ready_p2" ]; then
                clean_flags; pick_word; reset_history; s1=\$(get_score 1); s2=\$(get_score 2)
                broadcast_json "{\"type\": \"new_round\", \"scores\": {\"1\": \$s1, \"2\": \$s2}}"
            else
                p1_r=\$([ -f "\$PIPE_DIR/ready_p1" ] && echo true || echo false)
                p2_r=\$([ -f "\$PIPE_DIR/ready_p2" ] && echo true || echo false)
                broadcast_json "{\"type\": \"ready_update\", \"p1_ready\": \$p1_r, \"p2_ready\": \$p2_r}"
            fi
            ;;

        "reset_request")
            broadcast_json "{\"type\": \"reset_flash\"}"
            touch "\$PIPE_DIR/reset_p\$MY_ID"
            if [ -f "\$PIPE_DIR/reset_p1" ] && [ -f "\$PIPE_DIR/reset_p2" ]; then
                clean_flags; echo "0" > "\$PIPE_DIR/score_p1"; echo "0" > "\$PIPE_DIR/score_p2"
                reset_history; pick_word
                broadcast_json "{\"type\": \"new_match_start\", \"scores\": {\"1\": 0, \"2\": 0}}"
            fi
            ;;
            
        "submit_win")
            name=\$(echo "\$line" | jq -r '.name' | cut -c1-10)
            mariadb -u"\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" -e "INSERT INTO leaderboard (name, wins) VALUES ('\$name', 1) ON DUPLICATE KEY UPDATE wins = wins + 1;"
            json_lb=\$(mariadb -u"\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" -B -e "SELECT name, wins FROM leaderboard ORDER BY wins DESC LIMIT 10;" | awk 'NR>1 { print "{\"name\": \"" \$1 "\", \"wins\": " \$2 "}" }' | jq -s -c '.') 
            if [ -z "\$json_lb" ]; then json_lb="[]"; fi
            msg=\$(jq -n -c --arg name "\$name" --argjson lb "\$json_lb" '{"type": "show_leaderboard", "data": \$lb, "winner": \$name}')
            broadcast_json "\$msg"
            ;;

        "rematch_request")
            touch "\$PIPE_DIR/rematch_p\$MY_ID"
            if [ -f "\$PIPE_DIR/rematch_p1" ] && [ -f "\$PIPE_DIR/rematch_p2" ]; then
                clean_flags; echo "0" > "\$PIPE_DIR/score_p1"; echo "0" > "\$PIPE_DIR/score_p2"
                reset_history; pick_word
                broadcast_json "{\"type\": \"new_match_start\", \"scores\": {\"1\": 0, \"2\": 0}}"
            else
                count=\$(ls "\$PIPE_DIR"/rematch_p* 2>/dev/null | wc -l)
                broadcast_json "{\"type\": \"rematch_update\", \"count\": \$count}"
            fi
            ;;
            
        "claim_forfeit")
            enemy_id=\$([ "\$MY_ID" -eq 1 ] && echo 2 || echo 1)
            if [ ! -d "\$PIPE_DIR/p\${enemy_id}_lock" ]; then
                echo "2" > "\$PIPE_DIR/score_p\$MY_ID"; echo "0" > "\$PIPE_DIR/score_p\$enemy_id"
                s1=\$(get_score 1); s2=\$(get_score 2)
                target=\$(cat "\$PIPE_DIR/current_word")
                winner_name=\$([ "\$MY_ID" -eq 1 ] && echo "BLUE" || echo "RED")
                hist=\$(get_full_history)
                mariadb -u"\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" -e "INSERT INTO match_history (winner, target_word, score_blue, score_red) VALUES ('\$winner_name', '\$target', \$s1, \$s2);"
                send_json "{\"type\": \"ask_name\"}"
                msg=\$(jq -n -c --arg win "\$MY_ID" --argjson h "\$hist" '{"type": "wait_for_leaderboard_proxy", "winner_id": (\$win|tonumber), "history": \$h, "msg": "Opponent disconnected. You win!"}')
                broadcast_json "\$msg"
            fi
            ;;
    esac
done
EOF
chmod +x "$INSTALL_DIR/wardle.sh"

# --- 4d. Web Client (With 2026 Copyright) ---
cat << 'HTML_EOF' > "$WEB_ROOT/index.html"
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
        const socket = new WebSocket('ws://' + window.location.hostname + ':8080');
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
                box.id = `\${id}-box-\${i}`;
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
                        let box = document.getElementById(`op-grid-box-\${startIndex + i}`);
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
                tr.innerHTML = `<td>\${row.name}</td><td>\${row.wins}</td>`;
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
                let box = document.getElementById(`\${gridId}-box-\${startIndex + i}`);
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
HTML_EOF
echo "   [OK] Web client deployed to $WEB_ROOT/index.html"

echo "=========================================="
echo " INSTALLATION COMPLETE!"
echo "=========================================="
echo "1. Start the Game Server with this command:"
echo "   websocketd --port=8080 --address=0.0.0.0 $INSTALL_DIR/wardle.sh"
echo ""
echo "2. Open your browser to:"
echo "   http://127.0.0.1/index.html"
echo ""