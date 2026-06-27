# Cusco — Voxel City Blueprint

> **Scale:** 280x140x280 voxels (X=280 east-west, Y=140 vertical, Z=280 north-south)
> **Engine:** CubeLove (NanoVDB + brickmap + WGSL, see `2026-06-25-cubelove-engine-sota-voxel-beauty-plan-v2.md`)
> **Created:** 2026-06-26
> **Status:** Chief Architect blueprint — ready for voxel world export

---

## 1. City Identity

Cusco is the ancient navel of the Inca world — a city carved from living stone at 3,400 meters where massive trapezoidal foundations rise from the earth like geological formations, their perfectly fitted mortarless blocks bearing centuries of colonial Baroque churches, red-tile roofs, and wrought-iron balconies stacked atop Inca engineering that has survived five centuries of earthquakes. The city sits in a bowl-shaped Andean valley cradled by steep green hillsides terraced in precise geometric staircases, the Huatanay River threading through its center, while snow-capped peaks of the Cordillera Vilcanota frame every horizon and the thin mountain air amplifies sunlight into an intense, crystalline gold that shifts to rapid rose-and-violet sunsets in minutes. This is a city of layers — geological, cultural, temporal — where every stone tells two stories, llamas wander markets bursting with tropical fruit and woven textiles, and the air itself feels ancient, sacred, and impossibly clear.

---

## 2. Terrain Map

### 2.1 World dimensions and coordinate system

```
World: 280 (X, east-west) x 140 (Y, vertical) x 280 (Z, north-south)
Origin (0,0,0): southwest corner, ground level
Y=0: bedrock / lowest excavation
Y=80: average city floor elevation (valley floor)
Y=140: sky cap

Coordinate grid (X x Z):
  0-40:    Western hills (steep, terraces)
  40-80:   Western residential slope
  80-200:  Valley floor / city center
  200-240: Eastern residential slope
  240-280: Eastern hills (Sacsayhuamán above)

  0-60:    Southern hills (Cristo Blanco)
  60-220:  City core (N-S)
  220-280: Northern approach / San Pedro area
```

### 2.2 Elevation profile (Y values from valley floor)

| Feature | Y range | Description |
|---------|---------|-------------|
| Valley floor | Y=75-85 | Flat river plain, main city grid |
| Huatanay River | Y=74-76 | Channel cut 2-4 voxels below street level |
| Western slopes | Y=85-130 | Inca terraces to hilltop |
| Eastern slopes | Y=85-120 | Residential to Sacsayhuamán base |
| Sacsayhuamán plateau | Y=110-125 | Fortress on hilltop above city |
| Cristo Blanco hill | Y=100-125 | Steep southern prominence |
| Snow peaks (horizon) | Y=130-140 | Distant background, not traversable |

### 2.3 Terrain layers (bottom to top)

```
Y=0-60:    Andean bedrock — dark granite (#3A3530), boulder scatter
Y=60-75:   Sub-soil transition — clay (#8B7355), partial Inca foundations visible
Y=74-76:   Huatanay River — flowing water (#4090B0) + cobble bed (#7A7A6A)
Y=75-85:   City floor — cobblestone streets (#8A8070), packed earth (#A09078)
Y=85-130:  Hillside — exposed rock + scrub (#6B8B60) + terrace walls (#8B7355)
Y=130-140: Snow line — ice (#E8F0FF) on distant peaks, sky gradient
```

### 2.4 Key terrain features

**Huatanay River** runs roughly Z=120-140, X=60-220. Originally channeled by the Inca in stone-lined banks. Width: 6-8 voxels. Depth: 2-3 voxels below adjacent streets. Stone embankment walls (#8B7355) on both sides. One arched stone bridge (X=140, Z=130) and two footbridges.

**Sacsayhuamán hill** occupies the northeast quadrant: X=200-270, Z=20-80. Rises from city level (Y=85) to plateau (Y=110-115) and peaks at Y=125. Steep western face (1:1 slope), gradual southern approach via switchback path.

**Western terraces** from X=20-60, Z=80-200. Each terrace is 4 voxels deep, 3 voxels high, with retaining walls of fitted stone. 8-12 tiers depending on slope.

**Cristo Blanco hill** at X=130-160, Z=10-50. Isolated prominence rising to Y=125. Steep all sides, accessed by stone stairway from the south.

### 2.5 Bedrock and soil palette

| Material | Hex | Placement |
|----------|-----|-----------|
| Deep granite | `#3A3530` | Y=0-40 bedrock |
| Medium granite | `#5A5550` | Y=40-60 bedrock |
| Clay subsoil | `#8B6B50` | Y=60-75, behind foundations |
| Packed earth | `#A09078` | Y=75-85, streets and plazas |
| Cobblestone | `#8A8070` | Street surfaces, mix with earth |
| River cobble | `#7A7A6A` | Riverbed |

---

## 3. Color Palette

### 3.1 Locked palette (from brief)

| Name | Hex | Usage |
|------|-----|-------|
| Inca stone | `#8B7355` | Primary wall material for all Inca foundations |
| Weathered stone | `#A09078` | Upper Inca walls, exposed surfaces, retaining walls |
| Terracotta | `#C4724A` | Roof tiles, flower pots, decorative elements |
| Adobe white | `#E8D8C8` | Colonial upper-story walls, plastered surfaces |
| Andean green | `#2C5C3A` | Trees, dense vegetation, garden center |
| Highland scrub | `#6B8B60` | Hillside grass, terrace crops, sparse vegetation |
| Colonial red | `#C83030` | Church doors, market accents, flags |
| Inca gold | `#F0E0A0` | Gold leaf accents on Qorikancha, ceremonial details |
| Andean blue (ACCENT) | `#2060A0` | Window shutters, church domes, water features |
| Market gold (ACCENT) | `#D4A040` | Market awnings, textile displays, ceremonial items |

### 3.2 Extended palette (derived, used sparingly)

| Name | Hex | Derivation | Usage |
|------|-----|-----------|-------|
| Deep shadow | `#2A2520` | Darken Inca stone 40% | Foundation bases, overhangs |
| Stone highlight | `#C0B8A8` | Lighten weathered stone 20% | Sunlit faces, lintels |
| Adobe cream | `#F5F0E5` | Lighten adobe white | Plaster highlights |
| River water | `#4090B0` | Cool Andean blue-shift | Huatanay River surface |
| Deep water | `#2A6888` | Darken river water | River depth, shadows |
| Grass bright | `#5AAA50` | Saturate highland green | Well-watered terrace tops |
| Frost | `#E8F0FF` | Cool white with blue | Dawn frost, snow peaks |
| Night stone | `#1A1815` | Very dark warm | Night-shadow Inca walls |
| Sunset gold | `#E8A030` | Warm shift of market gold | Sunset light bounce |
| Blood colonial | `#8B2020` | Darken colonial red | Aged red paint, timber |

### 3.3 Palette application rules

1. **Inca walls:** Bottom 3 rows `#8B7355`, top 4 rows `#A09078` (weathering gradient). Inner faces use `#7A6348` (shadow).
2. **Colonial walls:** Base `#E8D8C8` with `#F5F0E5` on upper 30%. Window frames `#2060A0`.
3. **Roofs:** Base `#C4724A` with `#A85A38` on shadow side. Never more than 2 roof colors adjacent.
4. **Terraces:** Wall `#8B7355`, soil top `#6B8B60` (dry) or `#5AAA50` (irrigated). Crop rows alternate.
5. **Night shift:** All colors darken 30% toward their shadow variant. `#8B7355` → `#5A4A35`.

---

## 4. District Layout

### 4.1 District map (top-down, X-Z grid)

```
Z=0 ─────────────────────────────────────────────────── Z=280
     NORTH

X=0  [Western   ] [Terrace    ] [    PLAZA    ] [Eastern  ]  X=280
     [Hills     ] [District   ] [    DE       ] [Slope    ]
     [Terraces  ] [Colonial   ] [    ARMAS    ] [Residential]
     [          ] [Quarter    ] [             ] [          ]
     [          ] [           ] [  Qorikancha ] [          ]
     [          ] [           ] [  + Santo D. ] [          ]
     [          ] [           ] [             ] [  Sacsay- ]
     [          ] [San Pedro  ] [  River →    ] [  huamán  ]
     [          ] [Market     ] [  Twelve-Ang ] [  Plateau ]
     [          ] [           ] [  Stone      ] [          ]
     [Cristo    ] [Residential] [  Bridge     ] [          ]
     [Blanco    ] [South      ] [             ] [          ]
     [Hill      ] [           ] [             ] [          ]
     SOUTH
```

### 4.2 District specifications

**A. Plaza de Armas (Central)**
- Coordinates: X=100-180, Z=110-170, Y=80-85
- Character: The ceremonial heart. Open cobblestone plaza, manicured garden center, two flanking churches on Inca foundations.
- Density: Low (open space). Elevation: Y=80 (valley floor).
- Buildings: Cathedral (northwest corner), Church of La Compañía (northeast), garden center with fountain.

**B. Qorikancha Quarter**
- Coordinates: X=110-160, Z=90-110, Y=80-90
- Character: Sacred Inca precinct. Temple of the Sun foundations visible beneath Santo Domingo.
- Density: Medium. Notable for gold-tinted Inca walls and the transition zone where Inca meets colonial.
- Buildings: Qorikancha complex, Santo Domingo church, cloister garden.

**C. Colonial Quarter**
- Coordinates: X=60-100, Z=100-180, Y=80-92
- Character: Narrow cobblestone streets, two-story colonial buildings with wooden balconies, Inca foundations visible at street level.
- Density: High. Steep streets climbing westward.
- Buildings: 20-30 colonial townhouses, small plazas, stone archways.

**D. San Pedro District (North)**
- Coordinates: X=80-140, Z=190-250, Y=78-85
- Character: Bustling market area. Covered market hall, surrounding street vendors, produce spills onto sidewalks.
- Density: Medium-High. Chaotic, colorful.
- Buildings: San Pedro Market (large covered structure), surrounding shops, juice stalls.

**E. Twelve-Angled Stone Street**
- Coordinates: X=130-170, Z=160-190, Y=80-85
- Character: Narrow Inca-walled street. The famous twelve-angled stone is mid-block. High walls on both sides.
- Density: Low (passage). Tourist focus.
- Buildings: Hatun Rumiyoc street with the famous stone, adjacent palace walls.

**F. Western Terrace District**
- Coordinates: X=20-80, Z=80-200, Y=80-130
- Character: Agricultural terraces climbing the western hillside. Stone retaining walls, irrigation channels, crop rows.
- Density: Very low (agricultural). No buildings, only occasional stone shelters.
- Features: 8-12 terrace tiers, irrigation channels, crop patterns.

**G. Eastern Slope (Residential)**
- Coordinates: X=180-240, Z=100-200, Y=80-105
- Character: Modern Cusco built over Inca foundations. Mixed residential. Less tourist, more lived-in.
- Density: Medium. Steeper streets.
- Buildings: 15-20 residential blocks, some with visible Inca base courses.

**H. Sacsayhuamán Plateau**
- Coordinates: X=200-270, Z=20-90, Y=110-125
- Character: Dominant hilltop fortress. Massive zigzag walls. Open esplanade above.
- Density: Very low (monument). Windy, exposed.
- Features: Three-tier zigzag walls, open ceremonial space, panoramic views.

**I. Cristo Blanco Hill**
- Coordinates: X=120-170, Z=10-60, Y=85-125
- Character: Steep hill south of city center. White Christ statue at summit. Stone stairway access.
- Density: Very low. Single landmark + path.
- Features: Cristo statue, switchback path, hillside scrub.

### 4.3 Street network

Main arteries (8-10 voxels wide):
- **Sol Avenue** (X=140, Z=60-220): North-south spine from Plaza to San Pedro
- **El Solar** (X=100-180, Z=140): East-west across Plaza de Armas
- **River Road** (X=60-220, Z=125): Along north bank of Huatanay

Secondary streets (5-6 voxels wide):
- Hatun Rumiyoc (Z=170, X=130-170)
- Triunfo slope (X=115, Z=100-130)
- Loreto alley (X=155, Z=100-130)

Narrow alleys (3-4 voxels wide):
- Colonial Quarter interior grid
- Market access lanes
- Terrace service paths

### 4.4 Elevation changes across districts

```
Y=125 ┤                          ■ Cristo    ■ Sacsay
Y=115 ┤                          ■ Hill      ■ huamán
Y=105 ┤              ░░░         ■           ■ Plateau
Y=95  ┤         ░░░░     ░░░     ■
Y=85  ┤    ░░░░    COLONIAL ░░░  ■  Eastern
Y=80  ┤ ░░░ PLAZA  QUARTER   ░░░■  Slope
Y=75  ┤    DE ARMAS      RIVER ■■
Y=70  ┤                    ░░░
      └──────────────────────────────────────
      W                                    E
```
