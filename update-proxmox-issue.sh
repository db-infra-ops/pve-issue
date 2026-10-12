#!/usr/bin/env bash
# Weiterentwicklung von bashclub/trmm-scripts (update-proxmox-issue.sh)
# Proxmox VE Login Screen
#   /etc/issue : kompakter Login-Screen (vor der Anmeldung sichtbar, daher ohne sensible Details)
#   /etc/motd  : volle Details (nach der Anmeldung)
# Default: ANSI/Unicode; --mono: ASCII ohne Farben
set -euo pipefail

if (( EUID != 0 )); then
    printf 'Bitte als root ausfuehren.\n' >&2
    exit 1
fi

exec python3 - "$@" <<'PY'
import argparse
import concurrent.futures as cf
import fcntl
import fnmatch
import glob
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
from datetime import datetime

T0 = time.monotonic()

parser = argparse.ArgumentParser(
    description='Proxmox Login-Screen (/etc/issue + /etc/motd) aktualisieren')
parser.add_argument('--mono', action='store_true',
                    help='ASCII ohne Farben/Rahmen')
parser.add_argument('--no-motd', action='store_true',
                    help='/etc/motd nicht schreiben')
parser.add_argument('--no-issue', action='store_true',
                    help='/etc/issue nicht schreiben')
parser.add_argument('--issue-full', action='store_true',
                    help='/etc/issue mit allen Details (vor dem Login sichtbar!)')
parser.add_argument('--list-guests', action='store_true',
                    help='VMs/LXCs mit VMID:Name auflisten (Default: nur x/y aktiv)')
parser.add_argument('--config', default='/etc/default/proxmox-issue', metavar='DATEI',
                    help='Konfigurationsdatei (Default /etc/default/proxmox-issue)')
parser.add_argument('--smart-ttl', type=int, default=3600, metavar='SEK',
                    help='SMART-Cache in Sekunden (Default 3600, 0 = immer abfragen)')
parser.add_argument('--reload-getty', action='store_true',
                    help='agetty --reload nach dem Schreiben (Login-Prompt neu zeichnen)')
parser.add_argument('--stdout', action='store_true',
                    help='Nur auf stdout ausgeben, keine Dateien schreiben (Test)')
args = parser.parse_args()
if args.no_motd and args.no_issue:
    parser.error('--no-motd und --no-issue schliessen beide Ziele aus')

WIDTH = 76          # Innenbreite des Rahmens = WIDTH + 2 (80 Spalten gesamt)
PAD = 2             # Abstand Text <-> Rahmen (links und rechts)
CW = WIDTH - 2      # Textbreite innerhalb des Rahmens
ENV = dict(os.environ, LC_ALL='C', LANG='C')
CACHE_DIR = '/var/cache/proxmox-issue'
UPDATES_TTL = 900   # Sekunden: apt list nur alle 15 Minuten
DEFAULT_CRITICAL = ('pve', 'corosync', 'ceph', 'zfs', 'pbs', 'proxmox',
                    'multipath', 'nut', 'networking')


def load_config(path):
    """KEY=WERT-Zeilen, '#' = Kommentar. Wird geparst, nicht als Shell ausgefuehrt."""
    conf = {}
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            for row in f:
                try:
                    tokens = shlex.split(row, comments=True)
                except ValueError:
                    continue
                for token in tokens:
                    key, eq, value = token.partition('=')
                    if eq and re.fullmatch(r'[A-Z_]+', key):
                        conf[key] = value
    except OSError:
        pass
    return conf


def conf_list(conf, key, default=()):
    if key not in conf:
        return tuple(default)
    return tuple(x for x in re.split(r'[\s,]+', conf[key]) if x)


CONFIG = load_config(args.config)
# Units, die bei "fehlgeschlagen" ignoriert werden (Wildcards erlaubt: ugreen-*)
IGNORE_UNITS = conf_list(CONFIG, 'IGNORE_UNITS')
# Namenspraefixe, bei denen ein Ausfall als ERROR statt WARN gilt
CRITICAL_UNITS = conf_list(CONFIG, 'CRITICAL_UNITS', DEFAULT_CRITICAL)
# Backup-Zeile ganz ausblenden (z. B. wenn Backups nicht ueber vzdump dieses Nodes laufen)
BACKUP_CHECK = CONFIG.get('BACKUP_CHECK', 'yes').lower() not in ('no', '0', 'false', 'off')
# Letztes Backup aelter als N Stunden = WARN (Default 48)
try:
    BACKUP_MAX_AGE_H = float(CONFIG.get('BACKUP_MAX_AGE_H', 48))
except ValueError:
    BACKUP_MAX_AGE_H = 48.0
# vzdump-Lauf "WARNINGS: n" nicht als WARN werten (Hinweis bleibt in der Zeile sichtbar)
BACKUP_IGNORE_WARNINGS = CONFIG.get('BACKUP_IGNORE_WARNINGS', 'no').lower() in ('yes', '1', 'true', 'on')
EXCLUDE_DISKS = ('zd', 'loop', 'ram', 'nbd', 'rbd', 'dm-', 'zram')

# Parallele Laeufe verhindern (z. B. wenn eine Abfrage haengt)
if not args.stdout:
    lock = open('/run/proxmox-issue.lock', 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit(0)


# ----------------------------------------------------------
# HILFSFUNKTIONEN
# ----------------------------------------------------------

def run(argv, timeout=8):
    if not shutil.which(argv[0]):
        return 127, ''
    try:
        p = subprocess.run(argv, capture_output=True, text=True,
                           errors='replace', timeout=timeout, check=False,
                           env=ENV)
        return p.returncode, p.stdout.strip()
    except subprocess.TimeoutExpired:
        return 124, ''
    except OSError:
        return 126, ''


def read_json(argv, timeout=12):
    _, output = run(argv, timeout)
    try:
        data = json.loads(output)
        return data if isinstance(data, dict) else {}
    except (ValueError, TypeError):
        return {}


def clean(value):
    return re.sub(r'[\x00-\x1f\x7f-\x9f]', '?', str(value))


def number(value):
    if isinstance(value, (float, int)) and not isinstance(value, bool):
        return float(value)
    if isinstance(value, str):
        m = re.search(r'\d+(?:\.\d+)?', value.replace(',', ''))
        if m:
            return float(m.group())
    return None


def pad(value, width):
    value = clean(value)
    return (value[:width - 1] + '~') if len(value) > width else value.ljust(width)


def join_capped(items, limit):
    out, used = [], 0
    for index, item in enumerate(items):
        if used + len(item) + 1 > limit:
            out.append(f'... +{len(items) - index}')
            break
        out.append(item)
        used += len(item) + 1
    return ' '.join(out) or '-'


def fmt_duration(seconds):
    days, rest = divmod(int(seconds), 86400)
    hours, rest = divmod(rest, 3600)
    parts = []
    if days:
        parts.append(f'{days}d')
    if days or hours:
        parts.append(f'{hours}h')
    parts.append(f'{rest // 60}m')
    return ' '.join(parts)


def fmt_age(seconds):
    seconds = max(0, int(seconds))
    if seconds < 3600:
        return f'{seconds // 60}m'
    if seconds < 172800:
        return f'{seconds // 3600}h'
    return f'{seconds // 86400}d'


def kver(name):
    return [int(x) for x in re.findall(r'\d+', name)]


# ----------------------------------------------------------
# COLLECTOR: SYSTEM, KERNEL, NETZWERK, LOAD
# Probleme: Liste aus (Schwere 1=WARN / 2=ERROR, Kurztext ohne Details)
# ----------------------------------------------------------

def collect_system():
    d = {'problems': []}
    _, host = run(['hostname', '-f'])
    if not host:
        _, host = run(['hostname'])
    d['host'] = host or os.uname().nodename

    _, version_info = run(['pveversion'])
    d['version'] = (version_info.split('/', 1)[1].split('/', 1)[0]
                    if '/' in version_info else '?')

    kernel = os.uname().release
    installed = [os.path.basename(p) for p in glob.glob('/lib/modules/*-pve')]
    expected = max(installed, key=kver, default='')
    pinned = ''
    try:
        with open('/etc/kernel/proxmox-boot-pin', encoding='utf-8') as f:
            pinned = f.read().strip()
    except OSError:
        pass
    if pinned:
        expected = pinned
    if not expected:
        status = 'UNKNOWN'
    elif expected == kernel:
        status = 'OK (pinned)' if pinned else 'OK'
    else:
        status = f'REBOOT? -> {expected}'
        d['problems'].append((1, 'Kernel-Reboot'))
    d['kernel'], d['kernel_status'] = kernel, status

    try:
        with open('/proc/uptime', encoding='utf-8') as f:
            d['uptime'] = fmt_duration(float(f.read().split()[0]))
    except (OSError, ValueError, IndexError):
        d['uptime'] = '-'

    _, ip_output = run(['ip', '-o', '-4', 'addr', 'show', 'scope', 'global'])
    ips, plain = [], []
    for ip_line in ip_output.splitlines():
        parts = ip_line.split()
        if len(parts) >= 4:
            ips.append(f'{parts[3]}({parts[1]})')
            plain.append(parts[3].split('/')[0])
    d['ips'], d['ips_plain'] = ips, plain

    try:
        d['load'] = ' '.join(f'{x:.2f}' for x in os.getloadavg())
    except OSError:
        d['load'] = '-'

    d['ram'] = '-'
    try:
        mem = {}
        with open('/proc/meminfo', encoding='utf-8') as f:
            for row in f:
                key, _, value = row.partition(':')
                if value.split():
                    mem[key] = int(value.split()[0])
        total = mem['MemTotal']
        avail = mem.get('MemAvailable', mem.get('MemFree', 0))
        d['ram'] = f'{100 * (total - avail) / total:.0f}% von {total / 1048576:.0f}G'
    except (OSError, KeyError, ValueError, ZeroDivisionError):
        pass

    d['root'] = '-'
    try:
        usage = shutil.disk_usage('/')
        pct = 100 * usage.used / (usage.used + usage.free)
        d['root'] = f'{pct:.0f}%'
        if pct >= 95:
            d['problems'].append((2, 'Root-FS'))
        elif pct >= 90:
            d['problems'].append((1, 'Root-FS'))
    except (OSError, ZeroDivisionError):
        pass
    return d


# ----------------------------------------------------------
# COLLECTOR: GASTSYSTEME
# ----------------------------------------------------------

def collect_guests():
    d = {'vms': [], 'lxcs': [], 'problems': []}
    _, out = run(['qm', 'list'], timeout=10)
    for row in out.splitlines()[1:]:
        p = row.split()
        if len(p) >= 3 and p[0].isdigit():
            d['vms'].append((p[0], p[1], p[2] == 'running'))
    _, out = run(['pct', 'list'], timeout=10)
    for row in out.splitlines()[1:]:
        p = row.split()
        if len(p) >= 3 and p[0].isdigit():
            d['lxcs'].append((p[0], p[-1], p[1] == 'running'))
    return d


# ----------------------------------------------------------
# COLLECTOR: DATASTORES UND ZFS
# ----------------------------------------------------------

def collect_storage():
    d = {'storages': [], 'zpools': [], 'zfs_warning': '', 'problems': []}
    _, out = run(['pvesm', 'status'], timeout=12)
    for row in out.splitlines()[1:]:
        p = row.split()
        if len(p) < 3:
            continue
        if p[2] == 'active' and len(p) >= 7:
            pct = number(p[6])
            flag = pct is not None and pct >= 90
            d['storages'].append((p[0], p[6], flag))
            if flag:
                d['problems'].append((2 if pct >= 95 else 1, 'Storage'))
        elif p[2] == 'disabled':
            d['storages'].append((p[0], 'off', False))
        else:
            d['storages'].append((p[0], 'OFFLINE', False))
            d['problems'].append((1, 'Storage'))

    if shutil.which('zpool'):
        _, out = run(['zpool', 'list', '-H', '-o', 'name,health,capacity'])
        for row in out.splitlines():
            p = row.split()
            if len(p) >= 3:
                pct = number(p[2])
                flag = pct is not None and pct >= 80
                d['zpools'].append((p[0], p[1], p[2], flag))
                if p[1] != 'ONLINE':
                    d['problems'].append((2, 'ZFS'))
                elif flag:
                    d['problems'].append((2 if pct >= 90 else 1, 'ZFS'))
        if d['zpools']:
            rc, check = run(['zpool', 'status', '-x'], timeout=10)
            if rc != 0:
                d['zfs_warning'] = 'ZFS-Status nicht abrufbar'
                d['problems'].append((1, 'ZFS'))
            elif check != 'all pools are healthy':
                d['zfs_warning'] = next((x.strip() for x in check.splitlines()
                                         if x.strip()), 'ZFS-Warnung')
                d['problems'].append((2, 'ZFS'))
    return d


# ----------------------------------------------------------
# COLLECTOR: CLUSTER
# ----------------------------------------------------------

def collect_cluster():
    d = {'text': 'Standalone', 'problems': []}
    if not (os.path.exists('/etc/pve/corosync.conf')
            or os.path.exists('/etc/corosync/corosync.conf')):
        return d
    rc, info = run(['pvecm', 'status'], timeout=8)
    if rc != 0:
        d['text'] = 'ERROR: pvecm status nicht erreichbar'
        d['problems'].append((2, 'Cluster'))
        return d
    fields = dict((k.strip(), v.strip())
                  for k, v in re.findall(r'^([^:\n]+):\s*(.+)$', info, re.M))
    quorate = fields.get('Quorate', '').lower() == 'yes'
    d['text'] = (f"{fields.get('Name', '?')} | Nodes: {fields.get('Nodes', '?')} "
                 f"| Votes: {fields.get('Total votes', '?')}/"
                 f"{fields.get('Expected votes', '?')} "
                 f"| Quorum: {'OK' if quorate else 'ERROR'}")
    if not quorate:
        d['problems'].append((2, 'Cluster-Quorum'))
    return d


# ----------------------------------------------------------
# COLLECTOR: CEPH
# ----------------------------------------------------------

def collect_ceph():
    d = {'text': 'nicht konfiguriert', 'extra': '', 'problems': []}
    if not (os.path.exists('/etc/pve/ceph.conf')
            or os.path.exists('/etc/ceph/ceph.conf')):
        return d
    if not shutil.which('ceph'):
        d['text'] = 'ERROR: Ceph-CLI fehlt'
        d['problems'].append((1, 'Ceph'))
        return d
    data = read_json(['ceph', '--connect-timeout', '5', 'status',
                      '--format', 'json'], timeout=10)
    if not data:
        d['text'] = 'ERROR: Ceph-Status nicht erreichbar'
        d['problems'].append((2, 'Ceph'))
        return d
    health = data.get('health') or {}
    status = health.get('status', 'UNKNOWN')
    osd = (data.get('osdmap') or {}).get('osdmap') or {}
    mon = len(data.get('quorum_names') or [])
    d['text'] = (f"{status} | OSD up/total: {osd.get('num_up_osds', '?')}/"
                 f"{osd.get('num_osds', '?')} | in: {osd.get('num_in_osds', '?')} "
                 f"| MON quorum: {mon}")
    if status != 'HEALTH_OK':
        d['extra'] = ', '.join(list((health.get('checks') or {}).keys())[:3])
        d['problems'].append((2 if status == 'HEALTH_ERR' else 1, 'Ceph'))
    return d


# ----------------------------------------------------------
# COLLECTOR: MULTIPATH (nur wenn installiert)
# ----------------------------------------------------------

def collect_mpath():
    d = {'text': None, 'extra': '', 'problems': []}
    if not (shutil.which('multipathd') or shutil.which('multipath')):
        return d
    if not shutil.which('multipathd'):
        d['text'] = 'ERROR: multipathd fehlt'
    else:
        rc, state = run(['systemctl', 'is-active', 'multipathd'], timeout=4)
        if rc != 0 or state != 'active':
            d['text'] = 'ERROR: multipathd nicht aktiv'
        else:
            rc, out = run(['multipathd', 'show', 'paths', 'raw',
                           'format', '%d %t %T %o'], timeout=8)
            if rc != 0:
                d['text'] = 'ERROR: Multipath-Pfade nicht abrufbar'
            else:
                total, broken = 0, []
                for row in out.splitlines():
                    p = row.split()
                    if len(p) != 4 or p[0].lower() in ('dev', 'device'):
                        continue
                    total += 1
                    if (p[1].lower() == 'failed'
                            or p[2].lower() in ('faulty', 'shaky')
                            or p[3].lower() == 'offline'):
                        broken.append(p[0])
                d['text'] = (f'ERROR: {len(broken)}/{total} Pfade defekt'
                             if broken else f'OK ({total} Pfade)')
                d['extra'] = ', '.join(broken)
                rc, out = run(['multipathd', 'show', 'maps', 'raw',
                               'format', '%n %t'], timeout=8)
                if rc == 0:
                    inactive = [r.split()[0] for r in out.splitlines()
                                if len(r.split()) >= 2
                                and r.split()[1].lower() != 'active']
                    if inactive:
                        d['text'] += f' | ERROR: {len(inactive)} Maps inaktiv'
                        d['extra'] += ('; ' if d['extra'] else '') + ', '.join(inactive)
    if 'ERROR' in d['text']:
        d['problems'].append((2, 'Multipath'))
    return d


# ----------------------------------------------------------
# COLLECTOR: NUT USV
# ----------------------------------------------------------

def nut_targets():
    items = []
    config_files = ['/etc/nut/upsmon.conf'] + sorted(
        glob.glob('/etc/nut/upsmon.conf.d/*.conf'))
    for filename in config_files:
        try:
            with open(filename, encoding='utf-8', errors='replace') as f:
                for row in f:
                    try:
                        tokens = shlex.split(row, comments=True)
                    except ValueError:
                        continue
                    if len(tokens) >= 2 and tokens[0].upper() == 'MONITOR':
                        items.append(tokens[1])
        except OSError:
            pass
    if not items:
        rc, local = run(['upsc', '-l'], timeout=5)
        if rc == 0:
            items += [f'{n.strip()}@localhost'
                      for n in local.splitlines() if n.strip()]
    return list(dict.fromkeys(items))


def read_ups(target):
    """Rueckgabe: (Text, Schwere 0/1/2)"""
    rc, data = run(['upsc', target], timeout=6)
    if rc != 0 or not data:
        return f'{target}: ERROR nicht erreichbar', 1
    fields = {}
    for row in data.splitlines():
        key, colon, value = row.partition(':')
        if colon:
            fields[key.strip()] = value.strip()
    raw = fields.get('ups.status', '')
    flags = set(raw.split())
    severity = 0
    if not raw:
        status, severity = 'UNKNOWN', 1
    elif 'FSD' in flags or 'LB' in flags:
        status, severity = f'WARN ({raw})', 2
    elif 'RB' in flags:
        status, severity = f'WARN ({raw})', 1
    elif 'OB' in flags:
        status, severity = f'BATTERIE ({raw})', 1
    elif 'OL' in flags:
        status = f'NETZ ({raw})'
    else:
        status = raw
    details = [f'{target}: {status}']
    if fields.get('battery.charge'):
        details.append(f"Akku {fields['battery.charge']}%")
    runtime = number(fields.get('battery.runtime'))
    if runtime is not None:
        details.append(f'Restlaufzeit {runtime / 60:.0f} min')
    if fields.get('ups.load'):
        details.append(f"Last {fields['ups.load']}%")
    return ' | '.join(details), severity


def collect_ups():
    d = {'lines': [], 'problems': []}
    if not shutil.which('upsc'):
        d['lines'] = ['NUT nicht installiert']
        return d
    targets = nut_targets()
    if not targets:
        d['lines'] = ['NUT: keine USV gefunden (upsc -l / upsmon.conf)']
        return d
    with cf.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(read_ups, targets[:10]))
    d['lines'] = [text for text, _ in results]
    worst = max((sev for _, sev in results), default=0)
    if worst:
        d['problems'].append((worst, 'USV'))
    if len(targets) > 10:
        d['lines'].append(f'{len(targets) - 10} weitere USV nicht angezeigt')
    return d


# ----------------------------------------------------------
# COLLECTOR: PHYSISCHE DATENTRAEGER (SMART, mit Cache)
# SATA-Attribute 177/202/231/233 und NVMe Percentage Used
# ----------------------------------------------------------

def smart_values(data):
    nvme = data.get('nvme_smart_health_information_log') or {}
    hours = number(nvme.get('power_on_hours'))
    wear = number(nvme.get('percentage_used'))
    warn = bool(nvme.get('critical_warning'))

    if hours is None:
        hours = number((data.get('power_on_time') or {}).get('hours'))

    attrs = (data.get('ata_smart_attributes') or {}).get('table') or []
    if hours is None:
        for attr in attrs:
            if attr.get('id') == 9:
                hours = number((attr.get('raw') or {}).get('value'))
                break

    if wear is None:
        for attr_id in (233, 177, 231, 202):
            for attr in attrs:
                if attr.get('id') != attr_id:
                    continue
                name = str(attr.get('name', '')).lower()
                norm = number(attr.get('value'))
                raw = number((attr.get('raw') or {}).get('value'))
                valid_norm = norm is not None and 0 <= norm <= 100

                if attr_id == 233 and any(
                        x in name for x in ('wearout', 'life_left', 'lifetime_remain')):
                    if valid_norm:
                        wear = 100 - norm
                elif attr_id == 177 and 'wear_level' in name:
                    if valid_norm:
                        wear = 100 - norm
                elif attr_id == 231 and any(
                        x in name for x in ('life_left', 'lifetime_remain', 'ssd_life')):
                    if valid_norm:
                        wear = 100 - norm
                elif attr_id == 202:
                    # Herstellerspezifisch: RAW nur, wenn der Name "used" nennt
                    if 'lifetime' in name and 'used' in name:
                        if raw is not None and 0 <= raw <= 100:
                            wear = raw
                    elif 'lifetime' in name and 'remain' in name:
                        if valid_norm:
                            wear = 100 - norm
                if wear is not None:
                    break
            if wear is not None:
                break
    return wear, hours, warn


def load_cache(name='smart'):
    try:
        with open(f'{CACHE_DIR}/{name}.json', encoding='utf-8') as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_cache(cache, name='smart'):
    os.makedirs(CACHE_DIR, mode=0o700, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=f'.{name}.', dir=CACHE_DIR)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(cache, f)
        os.replace(temp, f'{CACHE_DIR}/{name}.json')
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def collect_disks():
    d = {'rows': [], 'problems': []}
    blocks = read_json(['lsblk', '-J', '-d', '-o', 'NAME,TYPE,MODEL,SERIAL,ROTA'])
    disks = [x for x in blocks.get('blockdevices', [])
             if x.get('type') == 'disk'
             and not str(x.get('name') or '').startswith(EXCLUDE_DISKS)]
    cache = load_cache()
    now = time.time()

    def work(disk):
        name = str(disk.get('name'))
        model = str(disk.get('model') or '').strip()
        serial = str(disk.get('serial') or '').strip()
        key = f'{name}:{serial}'
        old = cache.get(key) if isinstance(cache.get(key), dict) else None
        if (old and args.smart_ttl > 0
                and now - float(old.get('ts', 0)) < args.smart_ttl):
            return key, old, False
        try:
            rota = str(disk.get('rota')).lower() in ('1', 'true')
            argv = ['smartctl', '-a', '-j']
            if rota:
                argv += ['-n', 'standby']   # schlafende HDDs nicht aufwecken
            data = read_json(argv + [f'/dev/{name}'], timeout=20)
            usable = any(k in data for k in (
                'nvme_smart_health_information_log',
                'ata_smart_attributes', 'smart_status'))
            if not usable:
                # Standby / kein SMART: letzten bekannten Wert weiterverwenden
                return key, old or {'ts': 0, 'model': model, 'serial': serial,
                                    'wear': None, 'hours': None,
                                    'health': '-'}, False
            wear, hours, warn = smart_values(data)
            passed = (data.get('smart_status') or {}).get('passed')
            if passed is False:
                health = 'FAIL'
            elif warn or (wear is not None and wear >= 80):
                health = 'WARN'
            elif passed is True:
                health = 'OK'
            else:
                health = '-'
            model = model or str(data.get('model_name') or 'unknown').strip()
            serial = serial or str(data.get('serial_number') or '-').strip()
            return key, {'ts': now, 'model': model, 'serial': serial,
                         'wear': wear, 'hours': hours, 'health': health}, True
        except Exception:
            return key, old or {'ts': 0, 'model': model, 'serial': serial,
                                'wear': None, 'hours': None,
                                'health': '-'}, False

    with cf.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(work, disks))

    new_cache, dirty = {}, False
    for disk, (key, entry, refreshed) in zip(disks, results):
        new_cache[key] = entry
        dirty = dirty or refreshed
        d['rows'].append((str(disk.get('name')), entry.get('model') or 'unknown',
                          entry.get('serial') or '-', entry.get('wear'),
                          entry.get('hours'), entry.get('health', '-')))
    if dirty or set(new_cache) != set(cache):
        try:
            save_cache(new_cache)
        except OSError:
            pass
    healths = [r[5] for r in d['rows']]
    if 'FAIL' in healths:
        d['problems'].append((2, 'Disk'))
    elif 'WARN' in healths:
        d['problems'].append((1, 'Disk'))
    return d


# ----------------------------------------------------------
# COLLECTOR: FEHLGESCHLAGENE SYSTEMD-UNITS
# ----------------------------------------------------------

def collect_services():
    d = {'text': '-', 'problems': []}
    rc, out = run(['systemctl', '--failed', '--no-legend', '--plain',
                   '--no-pager'], timeout=8)
    if rc != 0:
        d['text'] = 'WARN | systemctl nicht abrufbar'
        d['problems'].append((1, 'Dienste'))
        return d
    units = []
    for row in out.splitlines():
        tokens = [t for t in row.split() if t not in ('●', '*')]
        if tokens:
            units.append(tokens[0])
    def ignored(unit):
        short = unit.rsplit('.', 1)[0]
        return any(fnmatch.fnmatchcase(unit, p) or fnmatch.fnmatchcase(short, p)
                   for p in IGNORE_UNITS)

    skipped = sum(1 for u in units if ignored(u))
    units = [u for u in units if not ignored(u)]
    note = f' ({skipped} ignoriert)' if skipped else ''
    if not units:
        d['text'] = f'OK | 0 fehlgeschlagen{note}'
        return d
    critical = any(u.startswith(CRITICAL_UNITS) for u in units)
    shown = ', '.join(units[:4]) + (f' +{len(units) - 4}' if len(units) > 4 else '')
    d['text'] = (f"{'ERROR' if critical else 'WARN'} | "
                 f'{len(units)} fehlgeschlagen: {shown}{note}')
    d['problems'].append((2 if critical else 1, 'Dienste'))
    return d


# ----------------------------------------------------------
# COLLECTOR: AUSSTEHENDE UPDATES (apt, mit Cache)
# ----------------------------------------------------------

def collect_updates():
    d = {'text': '-', 'problems': []}
    now = time.time()
    data = load_cache('updates')
    if not (data.get('ts') and 0 <= now - float(data['ts']) < UPDATES_TTL):
        rc, out = run(['apt', 'list', '--upgradable'], timeout=40)
        if rc != 0:
            d['text'] = 'WARN | apt list nicht abrufbar'
            d['problems'].append((1, 'Updates'))
            return d
        pkgs = [r for r in out.splitlines() if '/' in r and 'upgradable' in r]
        data = {'ts': now, 'total': len(pkgs),
                'security': sum(1 for r in pkgs
                                if '-security' in r.split(None, 1)[0])}
        try:
            save_cache(data, 'updates')
        except OSError:
            pass
    try:
        index_age = now - os.stat('/var/lib/apt/lists').st_mtime
    except OSError:
        index_age = 0
    total, security = int(data.get('total', 0)), int(data.get('security', 0))
    stale = index_age > 7 * 86400
    prefix = 'WARN | ' if (security or stale) else ('OK | ' if not total else '')
    text = ('alles aktuell' if not total else f'{total} verfuegbar'
            + (f', davon {security} Sicherheit' if security else ''))
    if stale:
        text += f' | Paketindex {fmt_age(index_age)} alt'
    d['text'] = prefix + text
    if security or stale:
        d['problems'].append((1, 'Updates'))
    return d


# ----------------------------------------------------------
# COLLECTOR: LETZTES BACKUP (vzdump-Tasks, auch PBS)
# ----------------------------------------------------------

def collect_backup():
    d = {'text': None, 'problems': []}
    if not BACKUP_CHECK or not shutil.which('pvesh'):
        return d
    node = os.uname().nodename.split('.')[0]
    rc, out = run(['pvesh', 'get', f'/nodes/{node}/tasks', '--typefilter',
                   'vzdump', '--limit', '100', '--output-format', 'json'],
                  timeout=15)
    try:
        tasks = json.loads(out) if rc == 0 else None
    except ValueError:
        tasks = None
    if not isinstance(tasks, list):
        d['text'] = 'WARN | Task-Log nicht abrufbar'
        d['problems'].append((1, 'Backup'))
        return d
    done = [t for t in tasks if isinstance(t, dict) and number(t.get('endtime'))]
    if not done:
        d['text'] = 'keine Backup-Tasks gefunden'
        return d

    def ended(t):
        return number(t.get('endtime')) or 0

    def failed(t):
        st = str(t.get('status', ''))
        return st != 'OK' and not st.startswith('WARNINGS')

    now = time.time()
    last = max(done, key=ended)
    status = str(last.get('status', ''))
    age = now - ended(last)
    if status == 'OK':
        level, sev = 'OK', 0
    elif status.startswith('WARNINGS'):
        level, sev = ('OK', 0) if BACKUP_IGNORE_WARNINGS else ('WARN', 1)
    else:
        level, sev = 'ERROR', 2
    recent_fails = sum(1 for t in done
                       if t.get('id') and failed(t) and now - ended(t) < 86400)
    if sev == 0 and (age > BACKUP_MAX_AGE_H * 3600 or recent_fails):
        level, sev = 'WARN', 1
    when = datetime.fromtimestamp(ended(last)).strftime('%d.%m. %H:%M')
    text = f'{level} | {when} (vor {fmt_age(age)})'
    if recent_fails:
        text += f' | {recent_fails} Fehler/24h'
    if status and status != 'OK':
        # Grund der Einstufung anzeigen ("Warnungen" statt WARNINGS, damit die Faerbung passt)
        text += ' | ' + re.sub(r'^WARNINGS', 'Warnungen', status)[:30]
    d['text'] = text
    if sev:
        d['problems'].append((sev, 'Backup'))
    return d


# ----------------------------------------------------------
# ALLE COLLECTOR PARALLEL AUSFUEHREN
# ----------------------------------------------------------

TASKS = {
    'sys': collect_system, 'guests': collect_guests,
    'storage': collect_storage, 'cluster': collect_cluster,
    'ceph': collect_ceph, 'mpath': collect_mpath,
    'ups': collect_ups, 'disks': collect_disks,
    'services': collect_services, 'updates': collect_updates,
    'backup': collect_backup,
}
R = {}
with cf.ThreadPoolExecutor(max_workers=len(TASKS)) as pool:
    futures = {name: pool.submit(fn) for name, fn in TASKS.items()}
    for name, future in futures.items():
        try:
            R[name] = future.result()
        except Exception:
            R[name] = {'problems': [(1, f'Fehler:{name}')]}

SYS = {'host': '?', 'version': '?', 'kernel': '?', 'kernel_status': 'UNKNOWN',
       'uptime': '-', 'ips': [], 'ips_plain': [], 'load': '-', 'ram': '-',
       'root': '-'}
SYS.update(R['sys'])

problems = []
for name in TASKS:
    problems += R[name].get('problems', [])
if problems:
    worst = max(sev for sev, _ in problems)
    names = list(dict.fromkeys(text for _, text in sorted(problems, key=lambda x: -x[0])))
    shown = ', '.join(names[:4]) + (f' +{len(names) - 4}' if len(names) > 4 else '')
    STATUS = f"{'ERROR' if worst >= 2 else 'WARN'} | {shown}"
else:
    STATUS = 'OK'

STAMP = datetime.now().strftime('%d.%m.%Y %H:%M')
ELAPSED = time.monotonic() - T0


# ----------------------------------------------------------
# INHALT
# ----------------------------------------------------------

def build_rows(full):
    rows = []

    def line(value=''):
        rows.append(('text', clean(value)))

    def section(name):
        rows.append(('section', clean(name)))

    line(f"PROXMOX VE {SYS['version']} | {SYS['host']}")
    ips = SYS['ips_plain']
    line(f'Web-UI  : https://{ips[0]}:8006/' if ips else 'Web-UI  : -')
    line(f"IP      : {', '.join(SYS['ips']) if SYS['ips'] else '-'}")
    line(f"Kernel  : {SYS['kernel']} [{SYS['kernel_status']}]")
    line(f"Uptime  : {SYS['uptime']}")
    line(f"Load    : {SYS['load']} | RAM {SYS['ram']} | / {SYS['root']}")
    line(f'Status  : {STATUS}')
    if not full:
        return rows

    section('GAESTE / CLUSTER')
    g = R['guests']
    for label, key in (('VMs', 'vms'), ('LXCs', 'lxcs')):
        guests = g.get(key, [])
        if not guests:
            line(f'{label:<8}: -')
            continue
        running = [f'{i}:{n}' for i, n, up in guests if up]
        stopped = [f'{i}:{n}' for i, n, up in guests if not up]
        if not args.list_guests:
            line(f'{label:<8}: {len(running)}/{len(guests)} aktiv')
            continue
        line(f'{label:<8}: {len(running)}/{len(guests)} aktiv | '
             f'{join_capped(running, 180)}')
        if stopped:
            line(f"{'':<10}gestoppt: {join_capped(stopped, 100)}")
    line(f"Cluster : {R['cluster'].get('text', '-')}")
    line(f"Ceph    : {R['ceph'].get('text', '-')}")
    if R['ceph'].get('extra'):
        line(f"Ceph    ! {R['ceph']['extra']}")
    if R['mpath'].get('text') is not None:
        line(f"MPath   : {R['mpath']['text']}")
        if R['mpath'].get('extra'):
            line(f"MPath   ! {R['mpath']['extra']}")

    section('WARTUNG')
    line(f"Dienste : {R['services'].get('text', '-')}")
    line(f"Updates : {R['updates'].get('text', '-')}")
    if R['backup'].get('text') is not None:
        line(f"Backup  : {R['backup']['text']}")

    section('USV / NUT')
    for ups in R['ups'].get('lines', ['-']):
        line(f'USV     : {ups}')

    section('DATASTORES / ZFS')
    storages = R['storage'].get('storages', [])
    zpools = R['storage'].get('zpools', [])
    line(f'{"DATASTORES (USED)":<36}ZFS POOLS (USED)')
    for i in range(max(len(storages), len(zpools), 1)):
        left = right = ''
        if i < len(storages):
            name, usage, flag = storages[i]
            left = f'{pad(name, 21)} {usage:>6}' + (' WARN' if flag else '')
        if i < len(zpools):
            name, health, cap, flag = zpools[i]
            right = f'{pad(name, 12)} {health:<9} {cap:>5}' + (' WARN' if flag else '')
        line(f'{left:<36}{right}'.rstrip())
    if R['storage'].get('zfs_warning'):
        line(f"ZFS WARNING: {R['storage']['zfs_warning']}")

    section('PHYSICAL DISKS - WEAR USED / YEARS ON')
    line(f'{"DEVICE":<8} {"MODEL":<17} {"SERIAL":<22} {"WEAR":>5} {"YEARS":>5} {"SMART":>6}')
    disk_rows = R['disks'].get('rows', [])
    for name, model, serial, wear, hours, health in disk_rows:
        wear_text = f'{wear:.0f}%' if wear is not None else '-'
        years_text = f'{hours / 8766:.1f}' if hours is not None else '-'
        line(f'{pad(name, 8)} {pad(model, 17)} {pad(serial, 22)} '
             f'{wear_text:>5} {years_text:>5} {health:>6}')
        if len(serial) > 22:
            line(f'  Full serial {name}: {serial}')
    if not disk_rows:
        line('(keine physischen Blockdevices erkannt)')
    return rows


# ----------------------------------------------------------
# FORMATIERUNG: --mono ODER ANSI
# ----------------------------------------------------------

INDENT_RE = re.compile(r'^( *)([A-Za-z-]+ *[:!] |gestoppt: )?')


def wrap(value):
    """Umbruch; Folgezeilen rutschen unter die Wertespalte ('Label   : ')."""
    m = INDENT_RE.match(value)
    indent = len(m.group(0)) if m.group(2) else len(m.group(1)) + 3
    return textwrap.wrap(
        value, width=CW, subsequent_indent=' ' * indent,
        break_long_words=True, break_on_hyphens=False,
        replace_whitespace=False
    ) or ['']


RESET = '\x1b[0m'
CYAN = '\x1b[1;36m'
GREEN = '\x1b[1;32m'
YELLOW = '\x1b[1;33m'
RED = '\x1b[1;31m'
# Fusszeile: ANSI 44 = blauer Hintergrund, 1;37 = fette weisse Schrift.
# Alternativen: '\x1b[42;30m' gruen/schwarz, '\x1b[46;30m' cyan/schwarz, '\x1b[0m' ohne Balken
FOOTER_STYLE = '\x1b[44;1;37m'

COLOR_PATTERN = re.compile(
    r'HEALTH_WARN|HEALTH_ERR|HEALTH_OK|'
    r'REBOOT\?|DEGRADED|FAULTED|UNAVAIL|REMOVED|'
    r'FAILED|FAIL|ERROR|WARNING|OFFLINE|ONLINE|'
    r'BATTERIE|UNKNOWN|WARN|\bOK\b'
)


def colorize(value):
    def replace(match):
        word = match.group()
        if word in ('OK', 'ONLINE', 'HEALTH_OK'):
            color = GREEN
        elif word in ('HEALTH_WARN', 'REBOOT?', 'BATTERIE', 'WARN'):
            color = YELLOW
        else:
            color = RED
        return color + word + RESET
    return COLOR_PATTERN.sub(replace, value)


def render(rows):
    footer = ' ' * PAD + f'Stand: {STAMP} | erzeugt in {ELAPSED:.1f}s'
    if args.mono:
        output = ['=' * (WIDTH + 2)]
        for kind, value in rows:
            if kind == 'section':
                output.extend(['', '-- ' + value.upper() + ' ' +
                               '-' * max(0, WIDTH - len(value) - 2)])
            else:
                output.extend(' ' * PAD + text for text in wrap(value))
        output.extend(['-' * (WIDTH + 2), footer, '=' * (WIDTH + 2)])
    else:
        output = ['╔' + '═' * (WIDTH + 2) + '╗']
        for index, (kind, value) in enumerate(rows):
            if index == 1:
                output.append('╠' + '═' * (WIDTH + 2) + '╣')
            if kind == 'section':
                tag = f' {value} '
                output.append('╟─' + CYAN + tag + RESET +
                              '─' * max(0, WIDTH + 1 - len(tag)) + '╢')
                continue
            for text in wrap(value):
                output.append('║' + ' ' * PAD + colorize(text.ljust(CW)) +
                              ' ' * PAD + '║')
        output.append('╠' + '═' * (WIDTH + 2) + '╣')
        output.append('║' + FOOTER_STYLE + pad(footer, WIDTH + 2) + RESET + '║')
        output.append('╚' + '═' * (WIDTH + 2) + '╝')
    return '\n'.join(output) + '\n'


FILES = {}
if not args.no_issue:
    # agetty wertet in /etc/issue Backslash-Sequenzen aus (\n, \l, ...): escapen
    FILES['/etc/issue'] = render(build_rows(args.issue_full)).replace('\\', '\\\\')
if not args.no_motd:
    FILES['/etc/motd'] = render(build_rows(True))


# ----------------------------------------------------------
# AUSGABE: STDOUT ODER ALLE DATEIEN VORBEREITEN, DANACH ATOMAR ERSETZEN
# ----------------------------------------------------------

if args.stdout:
    for target, content in FILES.items():
        if len(FILES) > 1:
            print(f'### {target}')
        sys.stdout.write(content)
    sys.exit(0)

staged = []
try:
    for target, content in FILES.items():
        fd, temp = tempfile.mkstemp(prefix='.proxmox-banner.',
                                    dir=os.path.dirname(target))
        staged.append((temp, target))
        with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(temp, 0o644)
        os.chown(temp, 0, 0)
    for temp, target in staged:
        os.replace(temp, target)
finally:
    for temp, _ in staged:
        if os.path.exists(temp):
            os.unlink(temp)

if args.reload_getty and '/etc/issue' in FILES:
    run(['agetty', '--reload'], timeout=5)
PY
