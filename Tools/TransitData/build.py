#!/usr/bin/env python3
"""Builds the transit data PathOS bundles, from open sources.

    python3 Tools/TransitData/build.py metro    # Namma Metro: stations, coordinates, service, fares
    python3 Tools/TransitData/build.py track    # only each metro line's track, into metro.json as it is
    python3 Tools/TransitData/build.py platforms  # only which platform goes which way, into metro.json
    python3 Tools/TransitData/build.py bus      # BMTC: stops, routes, how often they run
    python3 Tools/TransitData/build.py city     # the launch screen's map of central Bengaluru
                                                # (add --from saved.json to reuse an Overpass answer)
    python3 Tools/TransitData/build.py          # all three

Run from the repository root. Downloads go through curl, which uses the system's certificates
(python.org's Python ships without them). Output lands in PathOS/Resources/Transit/.

Nothing here runs in the app. When BMRCL opens a line or BMTC's data changes, re-run it and
commit the JSON it writes.
"""

import csv
import difflib
import io
import json
import math
import re
import subprocess
import sys
import zipfile
from collections import Counter, defaultdict
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
OUT = ROOT / "PathOS" / "Resources" / "Transit"
USER_AGENT = "PathOS-TransitData/1.0 (personal app data build)"

# Roughly Bengaluru. Anything outside is a bad coordinate, not a far-flung station.
BOUNDS = (12.70, 77.30, 13.30, 77.90)
# BMTC runs out to Hosur, Chikkaballapura, Dabaspet and Kanakapura.
BUS_BOUNDS = (12.30, 76.90, 13.80, 78.30)


def fetch(url: str) -> bytes:
    result = subprocess.run(
        ["curl", "-sfL", "--max-time", "300", "-H", f"User-Agent: {USER_AGENT}", url],
        capture_output=True,
    )
    if result.returncode != 0:
        sys.exit(f"Download failed ({result.returncode}): {url}")
    return result.stdout


def distance(a, b) -> float:
    """Metres between two (lat, lon) pairs."""
    lat1, lon1, lat2, lon2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return 2 * 6_371_000 * math.asin(math.sqrt(h))


def inside(lat: float, lon: float, bounds=BOUNDS) -> bool:
    return bounds[0] <= lat <= bounds[2] and bounds[1] <= lon <= bounds[3]


# MARK: Metro

def simplify(name: str) -> str:
    name = name.lower()
    name = re.sub(r"\(.*?line\)", "", name)
    for long, short in (("station", "stn"), ("mysore", "mysuru"), ("stn.", "stn")):
        name = name.replace(long, short)
    return re.sub(r"[^a-z]", "", name)


def build_metro() -> None:
    service = json.loads((HERE / "metro_service.json").read_text())
    failures = []

    for line in service["lines"]:
        relation = json.loads(fetch(f"https://api.openstreetmap.org/api/0.6/relation/{line['osmRelation']}.json"))["elements"][0]
        stop_ids = [m["ref"] for m in relation["members"] if m["type"] == "node" and m["role"].startswith("stop")]
        nodes = {}
        for start in range(0, len(stop_ids), 100):
            batch = ",".join(map(str, stop_ids[start:start + 100]))
            for element in json.loads(fetch(f"https://api.openstreetmap.org/api/0.6/nodes.json?nodes={batch}"))["elements"]:
                nodes[element["id"]] = element

        names = line["stations"]
        if len(stop_ids) != len(names):
            failures.append(f"{line['name']}: OpenStreetMap has {len(stop_ids)} stops, the app lists {len(names)}")
            continue

        # The relation lists stops in running order, the same order as the app's list, so they're
        # matched by position. The name check catches a relation that's been reordered or extended.
        stations = []
        for index, (name, node_id) in enumerate(zip(names, stop_ids)):
            node = nodes[node_id]
            tags = node.get("tags", {})
            osm_name = tags.get("name:en") or tags.get("name", "")
            similarity = difflib.SequenceMatcher(None, simplify(name), simplify(osm_name)).ratio()
            if similarity < 0.6:
                failures.append(f"{line['name']} #{index}: '{name}' doesn't look like OpenStreetMap's '{osm_name}' ({similarity:.2f})")
            if not inside(node["lat"], node["lon"]):
                failures.append(f"{line['name']} #{index}: '{name}' is outside Bengaluru")
            stations.append({"name": name, "lat": round(node["lat"], 6), "lon": round(node["lon"], 6)})

        for a, b in zip(stations, stations[1:]):
            gap = distance((a["lat"], a["lon"]), (b["lat"], b["lon"]))
            if gap > 3_500:
                failures.append(f"{line['name']}: {a['name']} → {b['name']} is {gap:.0f} m apart")
        line["stations"] = stations
        failures += add_track(line, line["osmRelation"])
        del line["osmRelation"]

    if failures:
        sys.exit("Metro data didn't check out:\n  " + "\n  ".join(failures))

    service.pop("_comment", None)
    service["generated"] = date.today().isoformat()
    credit_track(service)
    write("metro.json", service)


# MARK: Platforms

WIKIPEDIA_API = "https://en.wikipedia.org/w/api.php"


def build_platforms() -> None:
    """Which platform at each station goes which way, into the metro.json already there: from
    each station's Wikipedia article, whose layout table names every platform with the station it
    runs to next, checked against the platforms OpenStreetMap has mapped. Where the two disagree,
    the platform is left out — a wrong platform is worse than none."""
    metro = json.loads((OUT / "metro.json").read_text())
    articles = station_articles()
    titles = sorted({article for line in metro["lines"] for s in line["stations"]
                     if (article := best_article(s["name"], articles))})
    texts = wikitext(titles)
    mapped = osm_platforms(metro)
    failures, kept, dropped = [], 0, []
    for line in metro["lines"]:
        names = [s["name"] for s in line["stations"]]
        for i, station in enumerate(line["stations"]):
            station.pop("platforms", None)
            article = best_article(station["name"], articles)
            ways = {}
            for number, towards, following in layout_platforms(texts.get(article, "")):
                way = direction(names, i, following, towards)
                if way and number not in ways.setdefault(way, []):
                    ways[way].append(number)
            # Checked against OpenStreetMap where it has the platform mapped.
            for way, numbers in list(ways.items()):
                theirs = mapped.get((line["id"], station["name"], way))
                if theirs and not set(theirs) & set(numbers):
                    dropped.append(f"{line['name']} · {station['name']} towards {way}: Wikipedia {numbers}, OpenStreetMap {theirs}")
                    del ways[way]
            if ways:
                station["platforms"] = {way: sorted(numbers, key=int) for way, numbers in ways.items()}
                kept += 1
            elif i not in (0, len(names) - 1):
                failures.append(f"{line['name']} · {station['name']}: no platforms read")
    for note in dropped:
        print(f"  left out, the sources disagree: {note}")
    for note in failures:
        print(f"  no platforms: {note}")
    print(f"  platforms for {kept} station stops")
    metro["sources"] = [source for source in metro.get("sources", []) if source["what"] != "Platforms by direction"] + [{
        "what": "Platforms by direction",
        "url": "https://en.wikipedia.org/wiki/List_of_Namma_Metro_stations",
        "licence": "CC BY-SA 4.0 (each station's article), checked against OpenStreetMap (ODbL 1.0)",
        "retrieved": date.today().isoformat(),
    }]
    write("metro.json", metro)


def station_articles() -> list:
    """The station articles linked from Wikipedia's list of Namma Metro stations."""
    answer = json.loads(fetch(f"{WIKIPEDIA_API}?action=parse&page=List_of_Namma_Metro_stations&prop=links&format=json&formatversion=2"))
    return [link["title"] for link in answer["parse"]["links"] if link.get("exists") and "station" in link["title"].lower()]


def best_article(name: str, articles: list):
    """The article for a station: by its name, or the part after a comma — "Sri Balagangadharanatha
    Swamiji Station, Hosahalli" is Hosahalli's."""
    keys = [name] + ([name.split(",")[-1]] if "," in name else [])
    best = max(articles, key=lambda title: max(likeness(key, title) for key in keys))
    return best if max(likeness(key, best) for key in keys) >= 0.85 else None


def likeness(a: str, b: str) -> float:
    def plain(text):
        text = re.sub(r"\(.*?\)", "", text.lower())
        for long, short in (("metro station", ""), ("station", ""), ("mysore", "mysuru"), ("bengaluru", ""), ("bangalore", "")):
            text = text.replace(long, short)
        return re.sub(r"[^a-z]", "", text)
    return difflib.SequenceMatcher(None, plain(a), plain(b)).ratio()


def wikitext(titles: list) -> dict:
    """Articles' wikitext by title, forty to a request."""
    from urllib.parse import quote
    texts = {}
    for start in range(0, len(titles), 40):
        batch = "|".join(titles[start:start + 40])
        answer = json.loads(fetch(f"{WIKIPEDIA_API}?action=query&prop=revisions&rvprop=content&rvslots=main"
                                  f"&format=json&formatversion=2&redirects=1&titles={quote(batch)}"))
        renamed = {r["to"]: r["from"] for r in answer["query"].get("redirects", [])}
        for page in answer["query"]["pages"]:
            if "revisions" in page:
                texts[renamed.get(page["title"], page["title"])] = page["revisions"][0]["slots"]["main"]["content"]
    return texts


STATION_LINK = re.compile(r"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]|\{\{stl\|Namma Metro\|([^}|]+)(?:\|[^}]*)?\}\}")


def linked_names(text: str) -> list:
    names = []
    for match in STATION_LINK.finditer(text):
        name = match.group(2) or match.group(1) or match.group(3)
        names.append(re.sub(r"\s*metro station.*$", "", name.strip(), flags=re.I))
    return names


def layout_platforms(text: str) -> list:
    """(platform, towards, next station) for each platform in an article's layout table."""
    found = []
    marks = list(re.finditer(r"Platform\s*[-–]?\s*(\d+)", text))
    for index, mark in enumerate(marks):
        end = marks[index + 1].start() if index + 1 < len(marks) else mark.end() + 900
        chunk = text[mark.end():min(end, mark.end() + 900)]
        towards = re.search(r"[Tt]owards\s*(?:→|←|&rarr;|&larr;)?\s*(.+)", chunk)
        following = re.search(r"Next\s*[Ss]tation:?'*\s*(.+)", chunk)
        towards = (linked_names(towards.group(1))[:1] or [None])[0] if towards else None
        following = (linked_names(following.group(1))[:1] or [None])[0] if following else None
        if towards or following:
            found.append((mark.group(1), towards, following))
    return found


def direction(names: list, index: int, following, towards):
    """Which end of the line a platform's trains run to: by the next station, which has to be a
    neighbour on this line — names here are near twins (Hongasandra, Singasandra), so only a close
    match counts — or else by the station it says it's towards."""
    if following:
        neighbours = [j for j in (index - 1, index + 1) if 0 <= j < len(names)]
        best = max(neighbours, key=lambda j: likeness(following, names[j]), default=None)
        if best is not None and likeness(following, names[best]) >= 0.9:
            return names[-1] if best > index else names[0]
        return None
    if towards:
        best = max(range(len(names)), key=lambda j: likeness(towards, names[j]))
        if best != index and likeness(towards, names[best]) >= 0.92:
            return names[-1] if best > index else names[0]
    return None


def osm_platforms(metro: dict) -> dict:
    """OpenStreetMap's numbered platforms that say where they go — "Towards Silk Institute",
    platform 2 — by line, station and the end of the line they run to."""
    answer = overpass('[out:json][timeout:120];(nwr["railway"="platform"](12.75,77.40,13.15,77.80);'
                      'nwr["public_transport"="platform"]["subway"="yes"](12.75,77.40,13.15,77.80););out tags center;')
    mapped = {}
    for element in answer.get("elements", []):
        tags = element.get("tags", {})
        number, name = tags.get("ref") or tags.get("local_ref"), tags.get("name", "")
        centre = element.get("center") or {"lat": element.get("lat"), "lon": element.get("lon")}
        if not number or not name.startswith("Towards ") or centre.get("lat") is None:
            continue
        towards = name[len("Towards "):]
        for line in metro["lines"]:
            names = [s["name"] for s in line["stations"]]
            for i, station in enumerate(line["stations"]):
                if distance((centre["lat"], centre["lon"]), (station["lat"], station["lon"])) > 250:
                    continue
                way = direction(names, i, None, towards)
                if way:
                    mapped.setdefault((line["id"], station["name"], way), []).append(number)
    return mapped


def build_track() -> None:
    """Adds each line's track to the metro.json already there, leaving its stations alone."""
    metro = json.loads((OUT / "metro.json").read_text())
    relations = {line["id"]: line["osmRelation"] for line in json.loads((HERE / "metro_service.json").read_text())["lines"]}
    failures = []
    for line in metro["lines"]:
        failures += add_track(line, relations[line["id"]])
    if failures:
        sys.exit("Metro track didn't check out:\n  " + "\n  ".join(failures))
    credit_track(metro)
    write("metro.json", metro)


def credit_track(metro: dict) -> None:
    """Says where the track came from, among the data's other sources."""
    metro["sources"] = [source for source in metro.get("sources", []) if source["what"] != "Track as laid"] + [{
        "what": "Track as laid",
        "url": "https://www.openstreetmap.org/relation/1798771",
        "licence": "ODbL 1.0, © OpenStreetMap contributors",
        "retrieved": date.today().isoformat(),
    }]


# The track is kept to within this of the rails as laid: well inside GPS's own error, and a
# twentieth of the points.
TRACK_TOLERANCE = 2.5
# Every station has to sit this close to its line's track, or the track is the wrong one.
STATION_TO_TRACK = 60.0


def add_track(line: dict, relation_id: int) -> list:
    """The line as laid, from its OpenStreetMap route: the route's ways joined end to end into one
    line from the first station to the last. A way the route leaves out is found among the
    rails around the gap. Returns what didn't check out."""
    full = json.loads(fetch(f"https://api.openstreetmap.org/api/0.6/relation/{relation_id}/full.json"))["elements"]
    relation = next(e for e in full if e["type"] == "relation" and e["id"] == relation_id)
    ways = {e["id"]: e["nodes"] for e in full if e["type"] == "way"}
    nodes = {e["id"]: (e["lat"], e["lon"]) for e in full if e["type"] == "node"}
    members = [ways[m["ref"]] for m in relation["members"]
               if m["type"] == "way" and m["role"] in ("", "route", "forward", "backward")]
    if not members:
        return [f"{line['name']}: its OpenStreetMap route has no track"]

    chain = list(members[0])
    if len(members) > 1 and chain[0] in (members[1][0], members[1][-1]):
        chain.reverse()
    for way in members[1:]:
        if chain[-1] not in (way[0], way[-1]):
            bridge = rails_between(chain[-1], {way[0], way[-1]}, nodes)
            if bridge is None:
                return [f"{line['name']}: a gap in the track near {nodes[chain[-1]]} that no rails close"]
            chain += bridge[1:]
        chain += (way if way[0] == chain[-1] else list(reversed(way)))[1:]
    points = [nodes[n] for n in chain]

    # Running from the first station, as the stations are listed.
    first = (line["stations"][0]["lat"], line["stations"][0]["lon"])
    if distance(first, points[-1]) < distance(first, points[0]):
        points.reverse()

    # In flat metres around the line's start for simplifying, then back.
    lat0 = math.radians(points[0][0])
    flat = [(lon * math.cos(lat0) * 111_320, lat * 111_320) for lat, lon in points]
    kept = douglas_peucker(flat, TRACK_TOLERANCE)
    track = [[round(y / 111_320, 6), round(x / (math.cos(lat0) * 111_320), 6)] for x, y in kept]

    failures = []
    along_before = -1.0
    for station in line["stations"]:
        offset, along = locate((station["lat"], station["lon"]), track)
        if offset > STATION_TO_TRACK:
            failures.append(f"{line['name']}: {station['name']} is {offset:.0f} m from the track")
        if along <= along_before:
            failures.append(f"{line['name']}: {station['name']} comes before the station listed ahead of it")
        along_before = along
    length = sum(distance(a, b) for a, b in zip(track, track[1:]))
    print(f"  {line['name']}: {len(track)} points, {length / 1000:.1f} km of track")
    line["track"] = track
    return failures


def rails_between(start: int, ends: set, nodes: dict):
    """The rails from one node to any of a set of others, by way of the metro track around them:
    for a route that leaves a way out. Nodes from the answer are added to `nodes`."""
    lats = [nodes[start][0]] + [nodes[n][0] for n in ends if n in nodes]
    lons = [nodes[start][1]] + [nodes[n][1] for n in ends if n in nodes]
    bbox = f"{min(lats) - 0.01},{min(lons) - 0.01},{max(lats) + 0.01},{max(lons) + 0.01}"
    answer = overpass(f'[out:json][timeout:60];way["railway"="subway"]({bbox});out body;>;out skel qt;')
    neighbours = defaultdict(set)
    for element in answer["elements"]:
        if element["type"] == "node":
            nodes[element["id"]] = (element["lat"], element["lon"])
        elif element["type"] == "way":
            for a, b in zip(element["nodes"], element["nodes"][1:]):
                neighbours[a].add(b)
                neighbours[b].add(a)
    # Shortest by distance along the rails.
    import heapq
    best, came, queue = {start: 0.0}, {}, [(0.0, start)]
    while queue:
        cost, node = heapq.heappop(queue)
        if node in ends:
            path = [node]
            while path[-1] != start:
                path.append(came[path[-1]])
            return path[::-1]
        if cost > best.get(node, math.inf):
            continue
        for other in neighbours[node]:
            step = cost + distance(nodes[node], nodes[other])
            if step < best.get(other, math.inf):
                best[other], came[other] = step, node
                heapq.heappush(queue, (step, other))
    return None


def locate(point, track):
    """Metres from a point to a track, and how far along the track it falls."""
    best, along, total = (math.inf, 0.0), 0.0, 0.0
    for a, b in zip(track, track[1:]):
        scale = math.cos(math.radians(a[0])) * 111_320
        bx, by = (b[1] - a[1]) * scale, (b[0] - a[0]) * 111_320
        px, py = (point[1] - a[1]) * scale, (point[0] - a[0]) * 111_320
        length = math.hypot(bx, by)
        t = min(max((px * bx + py * by) / (length * length), 0), 1) if length > 0 else 0
        offset = math.hypot(px - bx * t, py - by * t)
        if offset < best[0]:
            best = (offset, total + length * t)
        total += length
    return best


# MARK: Bus

BMTC_GTFS = "https://github.com/Vonter/bmtc-gtfs/raw/refs/heads/main/gtfs/bmtc.zip"
PEAK_WINDOWS = ((8 * 60, 11 * 60), (17 * 60, 20 * 60))


def clock_minutes(text: str) -> int:
    hours, minutes, _ = (int(part) for part in text.split(":"))
    return hours * 60 + minutes


def headway(departures: list, windows) -> int | None:
    """Average minutes between buses leaving inside the windows, if at least two do."""
    total = sum(end - start for start, end in windows)
    count = sum(1 for d in departures if any(start <= d < end for start, end in windows))
    return round(total / count) if count >= 2 else None


def off_peak_windows(first: int, last: int):
    """The service day minus the peak windows."""
    windows, cursor = [], first
    for start, end in PEAK_WINDOWS:
        if start > cursor:
            windows.append((cursor, min(start, last)))
        cursor = max(cursor, end)
    if last > cursor:
        windows.append((cursor, last))
    return [(a, b) for a, b in windows if b > a]


def build_bus() -> None:
    archive = zipfile.ZipFile(io.BytesIO(fetch(BMTC_GTFS)))

    def table(name):
        return csv.DictReader(io.TextIOWrapper(archive.open(name), encoding="utf-8-sig"))

    calendars = list(table("calendar.txt"))
    if len(calendars) != 1 or not all(calendars[0][day] == "1" for day in ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")):
        sys.exit("The feed now has more than one service calendar; teach build_bus about day types.")

    routes = {row["route_id"]: row for row in table("routes.txt")}
    trips = {row["trip_id"]: row for row in table("trips.txt")}

    # Each trip's stops, in order, with the scheduled departure at each.
    visits = defaultdict(list)
    for row in table("stop_times.txt"):
        visits[row["trip_id"]].append((int(row["stop_sequence"]), row["stop_id"], clock_minutes(row["departure_time"] or row["arrival_time"])))

    # Trips that call at the same stops in the same order are one pattern: a route in one direction.
    patterns = defaultdict(list)
    for trip_id, calls in visits.items():
        trip = trips.get(trip_id)
        if not trip or len(calls) < 2:
            continue
        calls.sort()
        key = (trip["route_id"], trip.get("direction_id", ""), trip.get("trip_headsign", ""), tuple(stop for _, stop, _ in calls))
        patterns[key].append([minute for _, _, minute in calls])

    stop_rows = {row["stop_id"]: row for row in table("stops.txt")}

    # The feed also carries KSRTC intercity services across Karnataka. They're real, but they
    # aren't city buses, so any pattern that leaves BMTC's area is left out.
    def in_area(stop):
        row = stop_rows.get(stop)
        return row is not None and inside(float(row["stop_lat"]), float(row["stop_lon"]), BUS_BOUNDS)

    regional = {key: value for key, value in patterns.items() if all(in_area(stop) for stop in key[3])}
    skipped = len(patterns) - len(regional)
    patterns = regional
    used_stops = sorted({stop for key in patterns for stop in key[3]}, key=lambda s: (stop_rows[s]["stop_name"], s))
    stop_index = {stop: index for index, stop in enumerate(used_stops)}
    route_ids = sorted({key[0] for key in patterns}, key=lambda r: routes[r]["route_short_name"])
    route_index = {route: index for index, route in enumerate(route_ids)}

    stops_out = []
    for stop in used_stops:
        row = stop_rows[stop]
        lat, lon = float(row["stop_lat"]), float(row["stop_lon"])
        towards = re.search(r"\(Towards (.+?)\)", row.get("stop_desc") or "")
        stops_out.append([row["stop_name"], towards.group(1) if towards else "", round(lat, 5), round(lon, 5)])

    patterns_out = []
    for (route_id, _, headsign, stops), schedules in patterns.items():
        schedules.sort(key=lambda times: times[0])
        departures = [times[0] for times in schedules]
        # The typical running time to each stop: the median over this pattern's trips.
        offsets = []
        for position in range(len(stops)):
            gaps = sorted(times[position] - times[0] for times in schedules)
            offsets.append(max(0, gaps[len(gaps) // 2]))
        first, last = departures[0], departures[-1]
        patterns_out.append({
            "r": route_index[route_id],
            "h": headsign,
            "s": [stop_index[stop] for stop in stops],
            # Minutes from each stop to the next: small numbers, which keeps the file small.
            "d": [max(0, b - a) for a, b in zip(offsets, offsets[1:])],
            "n": len(departures),
            "f": first,
            "l": last,
            "hp": headway(departures, PEAK_WINDOWS),
            "ho": headway(departures, off_peak_windows(first, last)),
        })

    if len(patterns_out) < 2_000:
        sys.exit(f"Only {len(patterns_out)} bus patterns survived; the feed has probably changed shape.")

    write("bus.json", {
        "generated": date.today().isoformat(),
        "source": {
            "what": "BMTC stops, routes and timetables",
            "url": "https://github.com/Vonter/bmtc-gtfs",
            "licence": "ODbL 1.0. Contains data from bmtc-gtfs, scraped from the Namma BMTC app; some contents © BMTC",
            "caveat": "The Namma BMTC app's timetables are known to be inaccurate, and only routes with live tracking are included.",
        },
        "stops": stops_out,
        "routes": [[routes[r]["route_short_name"], routes[r]["route_long_name"]] for r in route_ids],
        "patterns": patterns_out,
    })
    print(f"  {len(stops_out)} stops, {len(route_ids)} routes, {len(patterns_out)} patterns ({skipped} intercity patterns left out)")


# MARK: Launch-screen city

# Central Bengaluru, centred just east of MG Road: Cubbon Park to the west, Halasuru Lake to the
# east. The box is twice as tall as it is wide, like a phone, and the app fills the screen with it.
CITY_CENTER = (12.9745, 77.6070)
CITY_HEIGHT_KM = 5.2
CITY_ASPECT = 0.5
OVERPASS = [
    "https://overpass.private.coffee/api/interpreter",
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]

ROAD_CLASSES = {
    "major": {"motorway", "trunk", "primary", "motorway_link", "trunk_link", "primary_link"},
    "secondary": {"secondary", "tertiary", "secondary_link", "tertiary_link"},
    "minor": {"unclassified", "residential", "living_street", "pedestrian"},
    "service": {"service"},
}
GREEN = {("leisure", "park"), ("leisure", "garden"), ("leisure", "pitch"), ("leisure", "stadium"),
         ("landuse", "grass"), ("landuse", "forest"), ("landuse", "recreation_ground"),
         ("landuse", "cemetery"), ("natural", "wood")}

# Where the route may run, in the box's own 0–1 coordinates, worked out for the tightest phones
# once the box fills their screen: the iPhone SE crops the top and bottom, the tall phones the
# sides. The line keeps clear of the edges, the status bar and the name at the bottom; the start
# and the pin, being solid, keep a wider margin; and nothing goes near the mark in the middle.
# The app's tests check the result on real screen sizes.
ROUTE_AREA = (0.09, 0.12, 0.91, 0.83)          # left, top, right, bottom, for the line
MARKER_AREA = (0.13, 0.17, 0.87, 0.83)         # for the start dot, and the pin's head
ROUTE_KEEP_OUT = (0.22, 0.375, 0.78, 0.625)    # around the mark
ROUTE_FROM, ROUTE_TO = (0.24, 0.76), (0.76, 0.22)


def overpass(query: str) -> dict:
    for host in OVERPASS:
        result = subprocess.run(
            ["curl", "-s", "--max-time", "240", "-H", f"User-Agent: {USER_AGENT}", host, "--data-urlencode", f"data={query}"],
            capture_output=True,
        )
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            print(f"  {host} didn't answer; trying the next mirror")
    sys.exit("No Overpass server answered. Try again later.")


def douglas_peucker(points, tolerance):
    """Simplifies a polyline of (x, y) tuples, keeping its shape within `tolerance`."""
    if len(points) < 3:
        return points
    (ax, ay), (bx, by) = points[0], points[-1]
    dx, dy = bx - ax, by - ay
    length = math.hypot(dx, dy) or 1e-12
    worst, index = 0.0, 0
    for i, (px, py) in enumerate(points[1:-1], 1):
        d = abs(dy * px - dx * py + bx * ay - by * ax) / length
        if d > worst:
            worst, index = d, i
    if worst <= tolerance:
        return [points[0], points[-1]]
    return douglas_peucker(points[:index + 1], tolerance)[:-1] + douglas_peucker(points[index:], tolerance)


def build_city() -> None:
    lat0, lon0 = CITY_CENTER
    height_deg = CITY_HEIGHT_KM / 111.0
    width_deg = CITY_HEIGHT_KM * CITY_ASPECT / (111.0 * math.cos(math.radians(lat0)))
    north, south = lat0 + height_deg / 2, lat0 - height_deg / 2
    west, east = lon0 - width_deg / 2, lon0 + width_deg / 2
    # A little beyond the box, so roads run off the edges rather than stopping at them.
    pad = 0.06
    bbox = f"{south - height_deg * pad},{west - width_deg * pad},{north + height_deg * pad},{east + width_deg * pad}"

    def norm(lat, lon):
        return ((lon - west) / (east - west), (north - lat) / (north - south))

    classes = "|".join(sorted(set().union(*ROAD_CLASSES.values())))
    # `city --from saved.json` builds from a saved Overpass answer, for when the servers are busy.
    saved = sys.argv[sys.argv.index("--from") + 1] if "--from" in sys.argv else None
    data = json.loads(Path(saved).read_text()) if saved else overpass(f"""[out:json][timeout:180];(
        way["highway"~"^({classes})$"]({bbox});
        way["leisure"~"^(park|garden|pitch|stadium)$"]({bbox});
        way["landuse"~"^(grass|forest|recreation_ground|cemetery)$"]({bbox});
        way["natural"~"^(water|wood)$"]({bbox});
        relation["natural"="water"]({bbox});
        relation["leisure"="park"]({bbox});
        way["railway"="rail"]({bbox}););out geom;""")

    roads = {name: [] for name in ROAD_CLASSES}
    green, water, rail = [], [], []
    graph = defaultdict(dict)
    positions = {}

    def flat(points, tolerance):
        return [round(v, 4) for p in douglas_peucker(points, tolerance) for v in p]

    def rings(members):
        """Stitches a multipolygon's outer ways into closed rings."""
        pieces = [[(g["lat"], g["lon"]) for g in m["geometry"]] for m in members
                  if m["type"] == "way" and m.get("role") == "outer" and m.get("geometry")]
        done = []
        while pieces:
            ring = pieces.pop(0)
            grown = True
            while ring[0] != ring[-1] and grown:
                grown = False
                for i, piece in enumerate(pieces):
                    if piece[0] == ring[-1]:
                        ring += piece[1:]
                    elif piece[-1] == ring[-1]:
                        ring += piece[::-1][1:]
                    else:
                        continue
                    pieces.pop(i)
                    grown = True
                    break
            done.append(ring)
        return done

    for element in data["elements"]:
        tags = element.get("tags", {})
        if element["type"] == "relation":
            target = water if tags.get("natural") == "water" else green
            for ring in rings(element.get("members", [])):
                target.append(flat([norm(*p) for p in ring], 0.0004))
            continue
        points = [norm(g["lat"], g["lon"]) for g in element.get("geometry", [])]
        if len(points) < 2:
            continue
        highway = tags.get("highway")
        if highway:
            name = next(n for n, kinds in ROAD_CLASSES.items() if highway in kinds)
            roads[name].append(flat(points, 0.0004 if name in ("major", "secondary") else 0.0007))
            if name == "service":
                continue
            # The route search walks the real network, preferring the roads a map app would.
            cost = {"major": 1.0, "secondary": 1.15, "minor": 1.6}[name]
            for (a, pa), (b, pb) in zip(zip(element["nodes"], points), zip(element["nodes"][1:], points[1:])):
                positions[a], positions[b] = pa, pb
                length = math.hypot((pb[0] - pa[0]) * CITY_ASPECT, pb[1] - pa[1]) * cost
                graph[a][b] = min(graph[a].get(b, math.inf), length)
                graph[b][a] = min(graph[b].get(a, math.inf), length)
        elif tags.get("railway") == "rail":
            rail.append(flat(points, 0.0005))
        elif tags.get("natural") == "water":
            water.append(flat(points, 0.0004))
        elif any((k, tags.get(k)) in GREEN for k in ("leisure", "landuse", "natural")):
            green.append(flat(points, 0.0005))

    # The route: shortest over the real roads, kept inside the safe area and out of the middle.
    left, top, right, bottom = ROUTE_AREA
    kl, kt, kr, kb = ROUTE_KEEP_OUT

    def allowed(node):
        x, y = positions[node]
        return left <= x <= right and top <= y <= bottom and not (kl <= x <= kr and kt <= y <= kb)

    ml, mt, mr, mb = MARKER_AREA
    endpoints = [n for n in positions if allowed(n) and ml <= positions[n][0] <= mr and mt <= positions[n][1] <= mb]
    if not endpoints:
        sys.exit("No roads inside the route area.")
    near = lambda target: min(endpoints, key=lambda n: math.hypot(positions[n][0] - target[0], positions[n][1] - target[1]))
    start, goal = near(ROUTE_FROM), near(ROUTE_TO)

    import heapq
    best, previous, queue = {start: 0.0}, {}, [(0.0, start)]
    while queue:
        cost, node = heapq.heappop(queue)
        if node == goal:
            break
        if cost > best.get(node, math.inf):
            continue
        for nxt, length in graph[node].items():
            if not allowed(nxt):
                continue
            if cost + length < best.get(nxt, math.inf):
                best[nxt], previous[nxt] = cost + length, node
                heapq.heappush(queue, (cost + length, nxt))
    if goal not in best:
        sys.exit("No route between the chosen ends that stays clear of the mark.")
    path, node = [goal], goal
    while node != start:
        node = previous[node]
        path.append(node)
    route = [positions[n] for n in reversed(path)]

    write("launch-map.json", {
        "generated": date.today().isoformat(),
        "source": {"what": "Launch-screen map of central Bengaluru",
                   "url": "https://www.openstreetmap.org/copyright",
                   "licence": "ODbL 1.0, © OpenStreetMap contributors"},
        "aspect": CITY_ASPECT,
        "roads": roads,
        "green": green,
        "water": water,
        "rail": rail,
        "route": [round(v, 4) for p in route for v in p],
    }, folder=ROOT / "PathOS" / "Resources" / "LaunchMap")
    counts = ", ".join(f"{len(v)} {k}" for k, v in roads.items())
    print(f"  roads: {counts}; {len(green)} green, {len(water)} water, {len(rail)} rail; route {len(route)} points")


# MARK: Output

def write(name: str, payload, folder: Path = OUT) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / name
    path.write_text(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    print(f"Wrote {path.relative_to(ROOT)} ({path.stat().st_size / 1024:.0f} KB)")


if __name__ == "__main__":
    targets = [a for a in sys.argv[1:] if a in ("metro", "track", "platforms", "bus", "city")] or ["metro", "bus", "city"]
    if "metro" in targets:
        build_metro()
    elif "track" in targets:
        build_track()
    if "platforms" in targets:
        build_platforms()
    if "bus" in targets:
        build_bus()
    if "city" in targets:
        build_city()
