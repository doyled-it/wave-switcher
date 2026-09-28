#!/bin/sh
# Emit a JSON array of Wave Terminal work streams (tabs grouped by workspace) for
# the WaveSwitcher picker. Reads Wave's SQLite state DB read-only.
#
# Dependencies: sqlite3 only (built into macOS). No jq, no other tools.
#
# Output: [{ ws, wsName, color, tab, tabName, status, current }, ...]
#   ws      = 1-based workspace index (matches the Workspace menu order)
#   tab     = 1-based tab index within the workspace (matches Cmd+<n>)
#   status  = running | needs input | idle | —   (from the tab's flag color)
#   current = 1 if this is the active tab of the active window (else 0)

DB="$HOME/Library/Application Support/waveterm/db/waveterm.db"
[ -f "$DB" ] || { echo "[]"; exit 0; }

exec /usr/bin/sqlite3 "file:$DB?mode=ro" "
SELECT COALESCE((
  SELECT json_group_array(json_object(
    'ws', wsidx, 'wsName', wsname, 'color', wscolor,
    'tab', tabpos, 'tabName', tabname, 'status', status, 'current', iscur,
    'tabId', tabid))
  FROM (
    SELECT
      (SELECT COUNT(*) FROM db_workspace w2 WHERE w2.rowid <= w.rowid) AS wsidx,
      json_extract(w.data,'\$.name')  AS wsname,
      json_extract(w.data,'\$.color') AS wscolor,
      je.key + 1 AS tabpos,
      je.value AS tabid,
      COALESCE(json_extract(t.data,'\$.name'),'tab') AS tabname,
      CASE lower(COALESCE(json_extract(t.data,'\$.meta.\"tab:flagcolor\"'),''))
        WHEN '#4a9eff' THEN 'running'
        WHEN '#a970ff' THEN 'subagents'
        WHEN '#e0b956' THEN 'needs input'
        WHEN '#58c142' THEN 'idle'
        ELSE '—' END AS status,
      CASE WHEN json_extract(w.data,'\$.oid') =
                (SELECT json_extract(data,'\$.workspaceid') FROM db_window LIMIT 1)
            AND je.value = json_extract(w.data,'\$.activetabid')
           THEN 1 ELSE 0 END AS iscur
    FROM db_workspace w
    JOIN json_each(json_extract(w.data,'\$.tabids')) je
    LEFT JOIN db_tab t ON json_extract(t.data,'\$.oid') = je.value
    ORDER BY w.rowid, je.key
  )
), '[]');
"
