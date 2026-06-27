# Chief Architect Plan: JAIPUR — The Pink City

**Scale:** 300 x 120 x 300 voxels (X = east-west, Y = elevation, Z = north-south)
**Coordinate origin:** Southwest corner at (0, 0, 0), Y-up

---

## 1. TERRAIN AND GEOGRAPHY

### 1.1 Base Terrain Profile

The Aravalli Hills run roughly north-south through the eastern portion of the build. The western half is the flat desert plain of Rajasthan.

| Zone | X Range | Z Range | Y (base) | Description |
|------|---------|---------|----------|-------------|
| **Desert Plain** | 0–200 | 0–300 | 0–4 | Flat arid plateau, gentle undulation ±2 voxels |
| **Aravalli Foothills** | 180–250 | 50–250 | 4–28 | Transition from plain to ridge, rocky scree |
| **Nahargarh Ridge** | 220–280 | 80–220 | 28–72 | Steep cliff face west, gradual east slope |
| **Dravyavati Riverbed** | 60–80 (varies) | 0–300 | 0–2 | Dry seasonal riverbed, south-to-north flow |
| **Man Sagar Lake** | 150–210 | 170–210 | 0–3 | Shallow lake bed, max depth 3 voxels |

### 1.2 Terrain Generation Rules

- **Desert floor:** Noise-based displacement ±2 voxels. Surface layer = 1 voxel `#C4A060` (golden sand) over 3 voxels `#8B7355` (desert brown) over bedrock.
- **Aravalli Hills:** Fractal ridgeline generation from z=80 to z=220, peak height 72 at (250, 150). Western face cliff at 60-degree angle. Exposed rock faces use `#8B7355` with `#C4A060` weathering streaks.
- **Nahargarh Ridge:** Continuous ridge at Y=50–72, length 140 voxels (z80–z220). Top is flat 6–8 voxels wide. Castle wall runs along entire ridge (see Landmark 5).
- **Dravyavati Riverbed:** Width 12–20 voxels, banks eroded 1–2 voxels below surrounding terrain. Bed is pale sandstone `#F0E0C8` with scattered brown `#8B7355` rocks. Meanders 3 times across its 300-voxel length.
- **Man Sagar Lake:** Oval basin, 60x40 voxels, depth 3 at center. Water level at Y=2. Bottom is muddy `#8B7355`. Banks are landscaped with ghats (stepped terraces) in `#E8C8A0`.

### 1.3 Geological Strata (visible on cliff faces)

| Depth from surface | Material | Color |
|---|---|---|
| 0 | Sand/dust | `#C4A060` |
| 1–3 | Desert soil | `#8B7355` |
| 4–12 | Sandstone | `#E8C8A0` |
| 13–20 | Red sandstone | `#C47050` |
| 21+ | Hard bedrock | `#7A6B55` |

---

## 2. COLOR PALETTE AND MATERIALS

### 2.1 Master Palette

| Name | Hex | Usage | Voxel Material |
|------|-----|-------|----------------|
| **Jaipur Pink** | `#D4836A` | Primary walls, building facades, Hawa Mahal | Terracotta, smooth |
| **Deep Pink** | `#C47050` | Accent trim, secondary walls, deep shadows | Terracotta, rough |
| **Sandstone** | `#E8C8A0` | Fort walls, temples, major structures | Stone, polished |
| **Cream Stucco** | `#F0E0C8` | Plastered walls, upper stories, interiors | Plaster, smooth |
| **Desert Brown** | `#8B7355` | Ground, earth, old wood, paths | Soil/dirt, rough |
| **Golden Sand** | `#C4A060` | Desert floor, sandstone trim, gold leaf accent | Sand, fine |
| **Garden Green** | `#4A6B4A` | Trees, garden hedges, courtyard plants | Foliage, dense |
| **Marble White** | `#F0E8D8` | Marble floors, columns, fine details | Marble, polished |
| **Blue Accent** | `#2060A0` | Door frames, window shutters, tiles | Painted wood, smooth |
| **Gold Accent** | `#D4A040` | Dome finials, railing caps, jewelry | Metal, shiny |

### 2.2 Extended Palette (procedural use)

| Name | Hex | Usage |
|------|-----|-------|
| Dust Haze | `#D4C4A080` (50% alpha) | Atmospheric dust overlay |
| Shadow Pink | `#9A5A42` | Shadowed pink facades |
| Lit Pink | `#E89878` | Sunlit pink facades at golden hour |
| Night Pink | `#7A4A3A` | Pink walls under moonlight |
| Water Blue | `#5A8AA0` | Man Sagar Lake water |
| Monsoon Green | `#5A8B5A` | Vegetation during rain |
| Turban Saffron | `#E89030` | Rajasthani turbans (NPCs) |
| Turban Red | `#C83030` | Marwari turban variant |
| Henna Brown | `#8B5A2B` | Henna/mehndi designs |
| Kite Red | `#E03030` | Kite festival |
| Kite Yellow | `#F0D020` | Kite festival |
| Kite Green | `#30A040` | Kite festival |
| Kite Blue | `#3060D0` | Kite festival |

### 2.3 Material Mapping Rules

- All pink surfaces: base `#D4836A`, lit side `#E89878`, shadow side `#9A5A42`
- Time-of-day shifts pink facade brightness: dawn warm-amber tint, noon full pink, dusk deep-rose glow, night muted mauve
- Sandstone: `#E8C8A0` with `#C4A060` weathering on horizontal surfaces
- Marble: `#F0E8D8` with subtle `#E0D8C8` veining (every 8th voxel offset)
- Desert ground: `#C4A060` with `#8B7355` scatter (15% of ground voxels)

---

## 3. THE NINE-GRID: JAIPUR'S URBAN LAYOUT

### 3.1 Maharaja Jai Singh's Plan (1727)

Jaipur was India's first planned city, laid out on a Vedic grid (Vastu Shastra). Nine rectangular sectors (chowkris) divided by 108-foot-wide avenues, with two additional sectors cut into the surrounding hills.

The voxel city replicates this grid within the western desert plain (X=0–200, Z=50–250).

### 3.2 Grid Layout

```
    Z=250 ┌────────┬────────┬────────┐
          │ Sector │ Sector │ Sector │
          │   7    │   8    │   9    │
    Z=200 ├────────┼────────┼────────┤
          │ Sector │ Sector │ Sector │
          │   4    │   5    │   6    │
    Z=150 ├────────┼────────┼────────┤
          │ Sector │ Sector │ Sector │
          │   1    │   2    │   3    │
    Z=100 └────────┴────────┴────────┘
          X=0      X=70     X=140    X=200
```

Each sector: approximately 65 x 50 voxels (allowing for avenue widths).

### 3.3 Avenue System

| Avenue | Direction | Width (voxels) | Position |
|--------|-----------|----------------|----------|
| **Chhoti Chaupar** (main E-W) | East-West | 12 | Z ≈ 150 |
| **Badi Chaupar** (main E-W) | East-West | 12 | Z ≈ 200 |
| **Main N-S Avenue** | North-South | 12 | X ≈ 100 |
| **Secondary streets** | Both | 6 | Every sector boundary |
| **Tertiary lanes** | Both | 3–4 | Within sectors |

### 3.4 Sector Functions

| Sector | Function | Key Features |
|--------|----------|--------------|
| **1** (SW) | **Johari Bazaar** (Landmark 6) | Gold market, narrow lanes, textile shops |
| **2** (S-center) | **City Palace** (Landmark 3) | Palace complex, courtyards, museum |
| **3** (SE) | **Jantar Mantar** (Landmark 4) | Observatory, open grounds |
| **4** (W-center) | **Residential / Havelis** | Merchant houses, courtyards |
| **5** (Center) | **Hawa Mahal** (Landmark 1) | Palace of Winds, main bazaar axis |
| **6** (E-center) | **Commercial / Crafts** | Workshops, pottery, textiles |
| **7** (NW) | **Residential** | Mixed housing, temples |
| **8** (N-center) | **Gardens / Ram Niwas** | Garden, zoo, museum |
| **9** (NE) | **Residential / Industrial** | Dye works, fabric printing |

### 3.5 Street Cross-Sections

**Main avenue (12 voxels wide):**
```
[W2][S3][R7][R7][S3][W2]
 W2  = Walkway: 2 voxels, `#E8C8A0` sandstone
 S3  = Sidewalk: 3 voxels, `#F0E0C8` cream
 R7  = Road: 7 voxels, `#8B7355` compacted earth/dust
```

**Secondary street (6 voxels wide):**
```
[W1][S1][R4][S1][W1]
```

**Tertiary lane (3–4 voxels wide):**
```
[R3] or [W1][R2][W1]
```

---

## 4. ARCHITECTURAL VOCABULARY

### 4.1 Building Typologies

#### 4.1.1 Haveli (Traditional Mansion)

The dominant residential form. Two-to-four-story courtyard houses.

| Element | Dimensions | Materials |
|---------|-----------|-----------|
| **Exterior walls** | 1 voxel thick | `#D4836A` pink, `#E8C8A0` sandstone trim |
| **Jharokha windows** | 2W x 3H x 2D projection | `#D4836A` frame, `#2060A0` shutters |
| **Chhajja (sunshade)** | Full-width, 1 voxel thick, 2 deep | `#C47050` deep pink |
| **Courtyard** | 8x8 to 12x12 interior | `#F0E8D8` marble floor |
| **Carved brackets** | 1x1x1 detail | `#E8C8A0` sandstone |
| **Rooftop** | Flat with low parapet | `#F0E0C8` cream stucco |

**Haveli generation rules:**
1. Place rectangular footprint (8–14 wide, 10–18 deep)
2. Hollow interior for courtyard (leave 2-voxel wall thickness)
3. Height: 2–4 stories (8–16 voxels)
4. Add jharokha windows every 4 voxels on street-facing walls (1st floor and above)
5. Add chhajja at each floor level (projects 2 voxels)
6. Courtyard: 1 central fountain (water source, `#5A8AA0`), 4 corner planters (`#4A6B4A`)
7. Entrance: ornate arched doorway, 2W x 4H, `#2060A0` blue door

#### 4.1.2 Temple (Mandir)

Hindu temple form with shikhara (tower).

| Element | Dimensions | Materials |
|---------|-----------|-----------|
| **Garbhagriha** (sanctum) | 5x5 base | `#E8C8A0` sandstone |
| **Mandapa** (hall) | 7x7 to 9x9 | `#E8C8A0`, `#F0E8D8` marble columns |
| **Shikhara** (tower) | 3x3 base, 8–12 high | `#F0E8D8` marble |
| **Kalasha** (finial) | 1x1x2 | `#D4A040` gold |
| **Entry torana** (arch) | 3W x 4H | `#E8C8A0` carved stone |

#### 4.1.3 Mosque (Masjid)

Smaller presence in the Hindu city, but architecturally distinct.

| Element | Dimensions | Materials |
|---------|-----------|-----------|
| **Prayer hall** | 10x8 | `#F0E8D8` marble, `#E8C8A0` sandstone |
| **Mihrab** (niche) | 2W x 3H, recessed 1 | `#F0E8D8` marble |
| **Minaret** | 2x2 base, 14 high | `#F0E8D8`, `#D4A040` cap |
| **Dome** | 4x4 base, 3 radius hemi | `#F0E8D8` marble |

#### 4.1.4 Shop / Workshop

Ground-level commercial units, 2 stories.

| Element | Dimensions | Materials |
|---------|-----------|-----------|
| **Shop front** | 4–6 wide, 3 deep | `#D4836A` pink walls |
| **Chabutra** (platform) | Full-width, 1H | `#E8C8A0` sandstone |
| **Display niche** | 2x2 recess | Interior goods |
| **Upper story** | Same footprint | `#F0E0C8` cream, jharokha window |
| **Signage** | 1-high strip | `#2060A0` or `#D4A040` paint |

### 4.2 Architectural Detail Library

#### Jharokha Window (overhanging enclosed balcony)
```
Side view:
    ┌───┐
    │   │  ← Window (2W x 3H)
  ┌─┤   ├─┐ ← Bracket support
  │ └───┘ │
  └───────┘ ← Chhajja above
```
- Corbelled out 2 voxels from wall face
- Supported by ornamental brackets (`#E8C8A0`)
- Lattice screen (jali) in opening: `#F0E8D8` marble, pattern: alternating solid/void
- Shutters: `#2060A0` blue (open) or `#C47050` deep pink (closed)

#### Chhajja (projecting eave)
- Full-width overhang at each floor
- 1 voxel thick, projects 2 voxels
- Supported by carved brackets every 3 voxels
- `#C47050` deep pink (darker than wall for shadow contrast)

#### Arched Doorway (Pols)
- Pointed arch (Rajput style): 2 wide at base, narrowing to 1, total height 5
- Frame: `#2060A0` blue or `#D4A040` gold
- Door: `#8B7355` dark wood with `#D4A040` studs
- Surround: `#E8C8A0` carved sandstone

#### Jali Screen (perforated stone lattice)
- `#F0E8D8` marble
- Patterns: geometric hexagonal, floral, star-and-polygon
- 1 voxel thick, rendered as alternating solid/void pixels in 2D plane

### 4.3 Building Density Rules

| Zone | Buildings/sector | Height (stories) | Footprint |
|------|-----------------|-------------------|-----------|
| **Bazaar cores** (sectors 1, 5) | 20–30 | 2–3 | 4x6 to 8x12 |
| **Residential** (sectors 4, 7, 9) | 10–15 | 2–4 | 8x10 to 14x18 |
| **Palace compound** (sector 2) | 3–5 large | 3–5 | 20x30+ |
| **Gardens** (sector 8) | 2–3 | 1–2 | Scattered |

---

## 5. LANDMARK 1: HAWA MAHAL (Palace of Winds)

### 5.1 Historical Context
Built in 1799 by Maharaja Sawai Pratap Singh. The 953 small windows (jharokhas) form a honeycomb facade allowing royal women to observe street festivals unseen. The structure is essentially a five-story screen wall, only one room deep.

### 5.2 Voxel Specification

**Footprint:** 22 wide (X) x 8 deep (Z) x 45 tall (Y)
**Position:** Sector 5, X=88–110, Z=190–198, ground at Y=4 (on raised plinth)

| Level | Y Range | Width (X) | Depth (Z) | Features |
|-------|---------|-----------|-----------|----------|
| **Crown** | 44–48 | 4 | 3 | Inverted lotus + 2 gold finials (`#D4A040`) |
| **5th floor** | 37–44 | 6 | 4 | Pyramid top, 2 rows jharokhas |
| **4th floor** | 30–37 | 10 | 5 | 3 rows jharokhas, chhajja |
| **3rd floor** | 23–30 | 14 | 6 | 3 rows jharokhas, chhajja |
| **2nd floor** | 16–23 | 18 | 7 | 4 rows jharokhas, chhajja |
| **1st floor** | 8–16 | 22 | 8 | 5 rows jharokhas, main entrance arch |
| **Plinth** | 4–8 | 22 | 8 | Stepped base, sandstone (`#E8C8A0`) |

### 5.3 Jharokha Window Grid

Total: 953 windows. Distributed as pyramid narrows.

| Floor | Windows (rows x cols) | Window size | Total |
|-------|-----------------------|-------------|-------|
| 1st | 5 rows x 11 cols | 2W x 3H x 2D | 55 |
| 2nd | 4 rows x 9 cols | 2W x 3H x 2D | 36 |
| 3rd | 3 rows x 7 cols | 2W x 3H x 2D | 21 |
| 4th | 3 rows x 5 cols | 2W x 2H x 2D | 15 |
| 5th | 2 rows x 3 cols | 2W x 2H x 1D | 6 |
| Interior courtyard faces | all levels combined | varies | ~820 |

**Rendering approach:** Each jharokha is a 2x3 voxel opening with `#F0E8D8` marble jali screen (alternating voxels). The 2-voxel depth creates a shadow cavity. Behind each window: 50% chance of `#2060A0` blue shutter (closed) or open dark cavity (interior).

### 5.4 Material Distribution

| Material | Percentage | Color |
|----------|-----------|-------|
| Jaipur Pink sandstone | 70% | `#D4836A` |
| Deep Pink trim | 15% | `#C47050` |
| Cream stucco (upper) | 10% | `#F0E0C8` |
| Marble jali screens | 3% | `#F0E8D8` |
| Gold finials | 1% | `#D4A040` |
| Blue shutters | 1% | `#2060A0` |

### 5.5 Unique Details

- **Pyramid profile:** Each floor is 2 voxels narrower on each side than the one below, creating the characteristic stepped pyramid silhouette.
- **Crown:** Double row of inverted-lotus motifs (`#F0E8D8` marble) topped by 2 gold-painted clay pots (kalasha, `#D4A040`), each 1x1x2 voxels.
- **Interior courtyard:** 8x8 marble-paved courtyard with a central fountain. Courtyard walls have simpler jharokha windows (2 rows only).
- **Street-facing chhajja:** Projects 3 voxels at ground level (extra-wide entrance canopy), 2 voxels at each upper floor.

---

## 6. LANDMARK 2: AMBER FORT (Amer Fort)

### 6.1 Historical Context
16 km from Jaipur proper, but included as the hilltop fortress-palace of the Kachwaha Rajputs. Built 1592–1727. Yellow and red sandstone with white marble palaces. Famous for Sheesh Mahal (Mirror Palace) with glass mosaic interior.

### 6.2 Voxel Specification

**Footprint:** 80 wide (X) x 60 deep (Z) x 55 tall (Y, from hill base to highest dome)
**Position:** Aravalli foothills, X=200–280, Z=100–160, built into hillside at Y=12–55

| Compound | X Range | Z Range | Y Range | Key Features |
|----------|---------|---------|---------|--------------|
| **Suraj Pol** (Sun Gate) | 200–210 | 128–132 | 12–22 | Main entrance, east-facing |
| **Jaleb Chowk** (Main Court) | 210–235 | 115–145 | 16–18 | Parade ground, 25x30 courtyard |
| **Diwan-i-Am** (Public Hall) | 235–255 | 120–140 | 18–28 | 40 columns, open pillared hall |
| **Ganesh Pol** (Gate) | 240–248 | 125–135 | 18–28 | Ornate painted gateway |
| **Sheesh Mahal** | 250–268 | 118–138 | 22–36 | Mirror palace, glass ceiling |
| **Sukh Mandir** | 255–270 | 125–140 | 22–32 | Pleasure gardens, water channels |
| **Zenana** (Women's quarters) | 260–275 | 115–145 | 24–36 | Private palace rooms |
| **Upper Fort Walls** | 195–285 | 95–165 | 28–55 | Perimeter walls along ridge |

### 6.3 Elephant Path

The iconic winding ascent from the base to Suraj Pol gate.

**Specification:**
- Path width: 8 voxels (accommodates elephant + rider)
- Total climb: Y=12 to Y=18 (6 voxels vertical rise)
- Path length: ~120 voxels (switchbacks 4 times)
- Surface: `#C4A060` golden sand, bordered by `#E8C8A0` sandstone retaining walls (2 voxels high)
- Each switchback has a flat rest platform (10x8 voxels)
- Guard positions at each turn: small towers (3x3x5, `#D4836A`)

### 6.4 Sheesh Mahal (Mirror Palace)

Interior gem of Amber Fort. Walls and ceiling covered in convex mirrors and colored glass.

**Interior treatment:**
- Floor: `#F0E8D8` marble in geometric pattern (every other voxel marble-white vs marble-shadow `#E0D8C8`)
- Walls: `#E8C8A0` sandstone base with mirror mosaic above
  - Mirror voxels: render as `#FFFFFF` with 20% random chance of sparkle/glint animation
  - Glass color voxels: `#2060A0` blue, `#D4A040` gold, `#E03030` red, `#30A040` green
  - Pattern: repeating geometric star in 5x5 voxel tiles
- Ceiling: Full mirror mosaic — every other voxel is mirror/sparkle, creating constellated ceiling effect
- Columns: 4 marble columns (`#F0E8D8`), each 2x2 base, 6 high, with gold capitals

### 6.5 Fort Walls and Towers

**Perimeter:** ~400 voxels of wall along the ridge.
- Wall height: 6–8 voxels, width: 3 voxels
- Material: `#E8C8A0` sandstone lower, `#C47050` deep pink upper
- Crenellations: alternating 1-voxel merlons (2 wide, 2 high) with 1-voxel gaps
- Watchtowers: every 40 voxels, 6x6 base, 12 high, conical roof (`#C47050`)
- Total towers: 10

---

## 7. LANDMARK 3: CITY PALACE

### 7.1 Historical Context
Built between 1729–1732 by Maharaja Sawai Jai Singh II. A sprawling complex of courtyards, gardens, and buildings covering one-seventh of the old city. Mix of Rajput, Mughal, and European architecture.

### 7.2 Voxel Specification

**Footprint:** 55 wide (X) x 45 deep (Z) x 40 tall (Y)
**Position:** Sector 2, X=68–123, Z=110–155

### 7.3 Compound Layout

```
    Z=155 ┌──────────────────────────────┐
          │   Mubarak Mahal (Museum)     │
          │        X=75-105              │
          ├──────────────────────────────┤
          │     Diwan-i-Khas             │
    Z=140 │   (Private Audience)         │
          │      Pritam Niwas            │
          ├──────┬───────┬───────────────┤
          │ Rose │ Court │  Peacock      │
    Z=125 │ Gate │  Y    │  Gate         │
          │      │       │               │
          ├──────┴───────┴───────────────┤
          │    Diwan-i-Am                │
          │  (Public Audience Hall)      │
    Z=110 └──────────────────────────────┘
          X=68    X=90    X=105   X=123
```

### 7.4 Four Famous Gates

| Gate | Direction | Size (WxH) | Colors | Motif |
|------|-----------|-----------|--------|-------|
| **Peacock Gate** (Mor Pol) | East | 5x8 | `#2060A0` blue, `#4A6B4A` green | Peacock motifs in 3x3 tiles |
| **Rose Gate** (Lotus Pol) | West | 5x8 | `#F0E8D8` marble, `#D4A040` gold | Petal border pattern |
| **Green Gate** | North | 4x7 | `#4A6B4A` green, `#F0E8D8` | Floral vines |
| **Courtyard Gate** | South | 4x7 | `#D4836A` pink, `#E8C8A0` | Geometric Rajput |

**Rendering for Peacock Gate:**
- Frame: `#2060A0` blue painted stone
- Inner panels: 3x3 voxel peacock motifs — body `#4A6B4A`, tail fan `#2060A0` + `#D4A040` eye spots
- Arch: pointed Rajput arch, `#D4A040` gold keystone

### 7.5 Key Halls

**Diwan-i-Am (Public Audience Hall):**
- Footprint: 30x15 voxels
- 27 pillars in 3 rows of 9 (`#F0E8D8` marble, each 2x2x8)
- Open sides (no walls between pillars)
- Raised platform at back for throne
- Gold-plated ceiling panels (`#D4A040`, every 4th ceiling voxel)

**Diwan-i-Khas (Private Audience):**
- Footprint: 15x12 voxels
- Two large silver urns (`#C0C0C8`, 2x2x3 each) — largest silver vessels in world
- Red carpet runner (`#C83030`, 3 wide, full length)
- Marble floor, mirrored ceiling (same as Sheesh Mahal pattern)

**Mubarak Mahal (Museum):**
- 3 stories, 20x15 footprint
- Blend of Rajput and European styles
- Arched windows with Gothic tracery (`#E8C8A0` stone)
- Clock tower: 4x4 base, 20 high, `#F0E8D8` marble, working clock face at top

---

## 8. LANDMARK 4: JANTAR MANTAR

### 8.1 Historical Context
Built 1728–1734 by Maharaja Sawai Jai Singh II. One of five astronomical observatories he built. Contains the world's largest stone sundial (27 meters). UNESCO World Heritage Site.

### 8.2 Voxel Specification

**Footprint:** 35 wide (X) x 35 deep (Z) x 30 tall (Y)
**Position:** Sector 3, X=145–180, Z=110–145, ground at Y=4

### 8.3 Major Instruments

#### 8.3.1 Samrat Yantra (Supreme Instrument / Giant Sundial)

The centerpiece. A massive triangular gnomon with a quadrant on each side.

| Component | Dimensions | Material |
|-----------|-----------|----------|
| **Gnomon (triangle)** | 27 high (Y=4–31), hypotenuse 30 long | `#E8C8A0` sandstone |
| **East quadrant arc** | Quarter-circle, radius 14 | `#F0E8D8` marble markings |
| **West quadrant arc** | Quarter-circle, radius 14 | `#F0E8D8` marble markings |
| **Staircases** | 2 flanking, 3 wide | `#E8C8A0` sandstone |
| **Hour markings** | Incised lines | `#C47050` deep pink paint |

**Construction in voxels:**
- The gnomon is a right triangle: vertical side (14 voxels wide at base, narrowing to 1 at top, 27 voxels tall)
- The hypotenuse must point to celestial north pole (tilted ~26.5° from horizontal at Jaipur's latitude)
- In voxels: approximate as stepped diagonal, each row 1 voxel closer to center
- Quadrant arc: semi-circle of 14-voxel radius drawn on ground plane, with 15 radial hour lines

#### 8.3.2 Ram Yantra (Observation Well)

Two complementary cylindrical buildings for measuring celestial altitude and azimuth.

| Component | Dimensions | Material |
|-----------|-----------|----------|
| **Outer cylinder** | 12 radius, 10 high | `#E8C8A0` sandstone |
| **Inner pillar** | 2 radius, 8 high | `#F0E8D8` marble |
| **Radial walls** | 12 spokes, 1 voxel thick | `#E8C8A0` sandstone |
| **Floor** | Divided into 12 sectors | `#F0E8D8` marble + `#8B7355` bronze markers |

#### 8.3.3 Jai Prakash Yantra (Hemisphere Sundial)

Two complementary hemispherical bowls.

| Component | Dimensions | Material |
|-----------|-----------|----------|
| **Bowl 1** | 7 radius, 4 deep | `#F0E8D8` marble |
| **Bowl 2** | 7 radius, 4 deep | `#F0E8D8` marble |
| **Gnomon wire** | Central thin rod | `#D4A040` gilded |
| **Markings** | Carved grid on concave surface | `#C47050` painted lines |

**Voxel rendering:** Hemispheres approximated as stepped semicircular layers. Each layer is a ring of voxels at the appropriate radius. The concave interior is covered with a grid of carved lines (every 3rd voxel: incised `#C47050` line).

#### 8.3.4 Other Instruments

| Instrument | Shape | Size | Purpose |
|------------|-------|------|---------|
| **Misra Yantra** | 5 connected instruments | 8x20x6 | Combined observation |
| **Dhruva Darshak** | Tall thin pillar | 1x1x15 | Pole star observation |
| **Niyat Chakra** | Vertical ring | 6 radius | Fixed ecliptic coordinates |
| **Dakshin Bhitti** | Wall-mounted arc | 12 high, arc 10 | Meridian transit |

### 8.4 Open Grounds

The observatory sits in a walled compound with:
- `#E8C8A0` sandstone boundary wall (3 high)
- `#F0E0C8` cream gravel paths between instruments
- Minimal vegetation (observatory needs clear sightlines)
- 2 entrance gates with `#D4A040` gold-trimmed pediments

---

## 9. LANDMARK 5: NAHARGARH FORT

### 9.1 Historical Context
Built in 1734 by Maharaja Sawai Jai Singh II as a retreat fortress on the Aravalli ridge. "Nahargarh" means "abode of tigers." The fort's long wall connects to Jaigarh Fort further along the ridge.

### 9.2 Voxel Specification

**Footprint:** 60 wide (X) x 40 deep (Z) x 25 tall (Y, from ridge surface)
**Position:** Nahargarh Ridge, X=230–290, Z=120–160, base at Y=48 (on ridge)

### 9.3 Layout

```
         Z=160 ┌────────────────────────────┐
               │    Extended Wall (west)     │
               │         ↓ 80 voxels ↓       │
               ├────┬──────────────┬────────┤
               │    │  Madhavendra │        │
               │    │   Bhawan     │        │
               │    │  (Palace)    │        │
               │    │  25x20x18   │        │
               │    │             │        │
         Z=120 ├────┴──────────────┴────────┤
               │      Front Courtyard       │
               └────────────────────────────┘
               X=230  X=250        X=270  X=290
```

### 9.4 Major Structures

**Madhavendra Bhawan (Palace):**
- Footprint: 25x20, height 18 voxels (Y=48–66)
- 9 identical suites for the king and his queens
- Arranged in 3x3 grid around central courtyard
- Material: `#D4836A` pink walls, `#F0E0C8` cream interiors
- Each suite: 7x7 interior, 1 jharokha window facing the valley below
- Interior murals: use `#E89030` saffron, `#2060A0` blue, `#4A6B4A` green paint panels on walls

**Ramparts and Wall Walk:**
- Total wall length: ~200 voxels along ridge
- Height: 6 voxels, width: 3 voxels with 2-voxel-wide walkway on top
- Crenellations: 1-voxel merlons every 2 voxels
- Material: `#E8C8A0` sandstone, matching Amber Fort walls
- The wall connects westward to Jaigarh Fort (extending beyond build boundary, fading into distance haze)

**Viewing Terraces:**
- 3 terraces on the western (city-facing) wall
- Each: 10x6 platform, 2 voxels above wall walk
- Low parapets (2 high) with jali screens
- From here, the entire pink grid of Jaipur is visible below

---

## 10. LANDMARK 6: JOHARI BAZAAR

### 10.1 Historical Context
The oldest and most famous market in Jaipur. Literally "jeweler's market." Narrow lanes packed with gold, silver, gemstone, and textile shops. A sensory explosion of color, sound, and commerce.

### 10.2 Voxel Specification

**Footprint:** 40 wide (X) x 25 deep (Z) x 10 tall (Y, max 3 stories)
**Position:** Sector 1, X=10–50, Z=125–150

### 10.3 Lane Structure

```
    Z=150 ┌──────────────────────────────┐
          │  ┌─┐┌─┐┌─┐  ┌─┐┌─┐┌─┐     │  ← 2nd floor shops
          │  └─┘└─┘└─┘  └─┘└─┘└─┘     │
          │  ════════════════════════   │  ← Main lane (4 wide)
          │  ┌─┐┌─┐┌─┐  ┌─┐┌─┐┌─┐     │  ← Ground floor shops
          │  └─┘└─┘└─┘  └─┘└─┘└─┘     │
    Z=137 ├───┤                    ├───┤
          │Side                    │Side│  ← Cross lanes (3 wide)
          │lane                    │lane│
          │  ┌─┐┌─┐┌─┐┌─┐┌─┐┌─┐  │    │
          │  └─┘└─┘└─┘└─┘└─┘└─┘  │    │
    Z=125 └──────────────────────────────┘
          X=10                     X=50
```

### 10.4 Shop Types (procedural placement)

| Shop Type | Count | Ground Floor | Upper Floor | Special |
|-----------|-------|-------------|-------------|---------|
| **Gold jeweler** | 8 | `#D4A040` gold displays, glass cases | Living quarters | Vaulted back room |
| **Silver smith** | 5 | `#C0C0C8` silver goods on shelves | Workshop | Anvil, furnace glow |
| **Textile** | 7 | Hanging fabrics: `#E89030`, `#C83030`, `#2060A0`, `#4A6B4A` | Storage | Bolts of cloth in windows |
| **Gem dealer** | 4 | Dark interior, spotlit displays | Counting room | Colored gem voxels: red, blue, green |
| **Pottery** | 3 | Stacked pots outside on chabutra | Kiln area | Terracotta pots `#C47050` |
| **Spice** | 4 | Open sacks of color: `#E89030`, `#C83030`, `#D4A040` | Storage | Cone-shaped spice mounds |
| **Bangle seller** | 3 | Wall of bangles: rainbow | Living | Rows of colored rings |

### 10.5 Atmospheric Details

- **Canopy:** Some lanes have cloth awnings stretched between buildings — `#E89030`, `#C83030`, `#2060A0` striped fabric (1 voxel thick, spanning 4–6 voxels across lane)
- **Signs:** Hand-painted wooden boards in Hindi script + English — `#2060A0` text on `#F0E8D8` background
- **Chabutra platforms:** Every 3rd shop has a raised platform (1 voxel high, `#E8C8A0`) where goods spill out
- **Henna designs:** Painted on some walls — `#8B5A2B` brown patterns on `#F0E0C8` cream plaster
- **Ceiling height:** Ground floor = 4 voxels, upper floor = 3 voxels (compressed proportion)

---

## 11. LANDMARK 7: JAL MAHAL (Water Palace)

### 11.1 Historical Context
Built in 1799 by Maharaja Madho Singh I as a lodge for duck hunting parties. Located in the middle of Man Sagar Lake. When the lake is full, only the top floor is visible above water. The palace has 5 stories, with 4 submerged.

### 11.2 Voxel Specification

**Footprint:** 30 wide (X) x 20 deep (Z) x 22 tall (Y)
**Position:** Center of Man Sagar Lake, X=170–200, Z=185–205, base at Y=0 (lake bed), water level at Y=2

### 11.3 Structure by Level

| Level | Y Range | Visibility | Features |
|-------|---------|------------|----------|
| **Lake bed** | 0–2 | Fully submerged | Foundation, sand/rock base |
| **1st floor** | 2–6 | Fully submerged | Storage, servants quarters |
| **2nd floor** | 6–10 | Fully submerged | Guest rooms |
| **3rd floor** | 10–14 | Partially submerged (water line) | Semi-exposed corridors |
| **4th floor** | 14–18 | Above water | Main palace rooms, chhatris |
| **5th floor / Roof** | 18–22 | Fully above | Garden terraces, domes |

### 11.4 Above-Water Features (Y=14–22)

- **Main terrace:** 20x14 platform with `#F0E8D8` marble floor
- **Chhatris (domed pavilions):** 4 corner chhatris, each 4x4 base, 5 high, `#F0E8D8` marble with `#D4A040` gold finials
- **Central dome:** 6 radius, 4 high, `#F0E8D8` marble
- **Garden:** Flat rooftop with `#4A6B4A` green planters and `#F0E8D8` marble walkways
- **Jharokha windows:** `#D4836A` pink sandstone frames, 2 rows on the 4th floor exterior
- **Arched openings:** `#E8C8A0` sandstone arches on all four sides

### 11.5 Submerged Sections

- Visible through water: `#5A8AA0` water tint applied to voxels below water line
- Foundation: `#8B7355` rough stone
- Lower walls: `#E8C8A0` sandstone, covered in green algae (`#3A6B3A` scattered on outer faces)

### 11.6 Lake and Surrounds

- **Lake shape:** Oval, 60x40 voxels, centered on X=180, Z=190
- **Water:** `#5A8AA0` surface, translucent 50% (see submerged palace through)
- **Lake bed:** `#8B7355` muddy brown
- **Ghats (stepped embankments):** Around entire lake perimeter, `#E8C8A0` sandstone, 3 steps descending to water
- **Lakefront path:** 3-voxel-wide promenade around ghats, `#F0E0C8` cream gravel
- **Trees:** `#4A6B4A` pipal and neem trees along the lakeside at irregular intervals

---

## 12. PERPETUAL PROCEDURAL RENDERING SYSTEMS

### 12.1 Time-of-Day Cycle (24-minute real-time = 24-hour day)

| Phase | Real Minutes | Sun Angle | Sky Color | Key Effect |
|-------|-------------|-----------|-----------|------------|
| **Dawn** | 0–3 | 5–30° E | `#FFB870` → `#87CEEB` | Golden light hits east facades first |
| **Morning** | 3–6 | 30–60° E | `#87CEEB` | Clear blue, sharp shadows |
| **Noon** | 6–12 | 60–90° overhead | `#5B9BD5` | Hardest light, minimal shadow, heat shimmer begins |
| **Afternoon** | 12–18 | 90–30° W | `#5B9BD5` → `#D4836A` | Lengthening shadows, pink facades glow |
| **Golden Hour** | 18–20 | 30–10° W | `#FF8C40` → `#FF6040` | Peak pink facade glow, deep amber, long shadows |
| **Dusk** | 20–21 | 10–0° W | `#FF6040` → `#4A3060` | Purple-pink gradient, city lights begin |
| **Night** | 21–24 | Below horizon | `#1A1030` → `#0A0818` | Moonlight on pink walls (cool blue-grey), streetlamps glow |

### 12.2 Desert Heat Shimmer

**Trigger:** Noon phase (real minutes 6–12), intensity peaks at minute 9.

**Implementation:**
- Horizontal displacement: sine wave on Y-axis, amplitude 0.5 voxels, frequency based on distance from ground
- Affected region: open desert plain only (X=0–180, away from buildings)
- Near ground: fast oscillation (high frequency)
- At Y=10: slow oscillation (low frequency)
- Near landmarks: no shimmer (buildings break convection)
- Color shift: slight warm overlay `#D4C4A080` on distant terrain

### 12.3 Dust Haze System

**Layered atmospheric dust, increases toward desert edge.**

| Distance from City Center | Dust Opacity | Color Tint |
|--------------------------|-------------|------------|
| 0–50 voxels (core) | 0% | None |
| 50–100 voxels | 5% | `#D4C4A008` |
| 100–150 voxels | 12% | `#D4C4A014` |
| 150–200 voxels | 20% | `#D4C4A028` |
| 200–300 voxels (desert edge) | 35% | `#D4C4A040` |

**Dust storm event (random, 5% chance per hour):**
- Entire city: +15% dust overlay
- Visibility drops to 80 voxels
- Sky shifts to `#C4A060` amber
- Duration: 2–4 real minutes
- Wind particles: `#C4A060` 1x1 voxels moving east at 3 voxels/second

### 12.4 Golden Hour Explosion on Pink Facades

**At golden hour (real minutes 18–20):**
- All pink (`#D4836A`) surfaces facing west shift to `#E89878` (lit pink)
- Deep pink (`#C47050`) shifts to `#D4836A` (warmed)
- Shadow faces remain `#9A5A42` (shadow pink)
- Sandstone (`#E8C8A0`) warms to `#F0D8B0`
- Marble (`#F0E8D8`) catches warm reflection: `#F8E8D0`
- Water (`#5A8AA0`) reflects sky: `#FF8C4040` orange overlay

### 12.5 Monkey Troops

**Behavior model:**
- 4 troops of 6–10 monkeys each
- Spawning: Amber Fort walls (2 troops), Nahargarh Fort walls (1 troop), City Palace walls (1 troop)
- Movement: follow wall tops, leap between buildings within 4-voxel gap
- Idle: sit on crenellations, groom each other
- Alert: sudden dash along wall, leap to rooftop
- Color: `#8B7355` brown body, `#C4A060` lighter face
- Size: 1x1x1 voxel (body) + 1x1 tail

### 12.6 Kite Festival System

**Trigger:** Random event, 10% chance during afternoon phase (real minutes 12–18).

| Property | Value |
|----------|-------|
| **Kite count** | 200–500 |
| **Altitude** | Y=40–100 (above rooftops, below cloud line) |
| **Colors** | `#E03030` red, `#F0D020` yellow, `#30A040` green, `#3060D0` blue, `#D4836A` pink, `#FFFFFF` white |
| **Size** | 2x2 or 3x3 voxels |
| **Movement** | Gentle drift: 0.5 voxels/sec horizontal, 0.2 voxels/sec vertical oscillation |
| **Strings** | 1-voxel-wide line from kite to rooftop (where "flyers" stand) |
| **Cut kites** | 5% of kites: no string, tumbling diagonally down, new random color |
| **Duration** | 3–5 real minutes |

### 12.7 Cow Presence on Streets

**Behavior:**
- 15–20 cows distributed across city
- Spawn: near temples, bazaars, main avenues
- Movement: slow meander (0.3 voxels/sec), follow streets, stop randomly
- Resting: 50% chance at any moment — lie down on sidewalk (`#F0E0C8` cream sidewalk is preferred)
- Color: `#C4A060` golden brown (Rajasthani cow breed) or `#F0E0C8` white
- Size: 2x1x1 voxels (body)

### 12.8 Turban Colors (NPC Pedestrians)

Rajasthani turbans (pagri) indicate region and caste. NPCs walk the streets.

| Turban Color | Hex | Meaning | Frequency |
|---|---|---|---|
| **Saffron** | `#E89030` | Rajput warrior | 25% |
| **Red** | `#C83030` | Marwari merchant | 20% |
| **White** | `#F0E8D8` | Elder / scholar | 15% |
| **Pink** | `#D4836A` | Jaipur local | 15% |
| **Yellow** | `#F0D020` | Festive / wedding | 10% |
| **Multi-colored** | various | Jat / farmer | 10% |
| **Blue** | `#2060A0` | Indigo dyer | 5% |

NPC rendering: 1x1x1 body + 1-voxel turban (color-coded), moving along street paths at 0.5–1 voxels/sec.

### 12.9 Henna Hand Designs on Walls

**Placement:** On `#F0E0C8` cream stucco walls in bazaar and residential zones.

**Patterns (2D pixel art mapped to wall face):**
- **Paisley** (5x7): `#8B5A2B` brown, repeating teardrop
- **Floral mandala** (7x7): `#8B5A2B` radial symmetry
- **Peacock feather** (5x9): `#8B5A2B` + `#2060A0` eye
- **Geometric lattice** (8x8): `#8B5A2B` interlocking diamonds

**Frequency:** 1 in every 8 cream walls has henna art. Each is a randomly selected pattern.

### 12.10 Bazaar Lifecycle

Shops open/close on a time cycle synchronized with the day.

| Time Phase | State | Visual |
|---|---|---|
| **Dawn (0–3)** | Opening | Shutters swing open (`#2060A0` → closed void → open interior), goods laid out on chabutras |
| **Morning (3–6)** | Peak | Full display: textile bolts unfurled, spice cones built, jewelry cases lit |
| **Noon (6–12)** | Slow | Awnings extended for shade, fewer NPCs, some shops closed for lunch |
| **Afternoon (12–18)** | Peak again | Second rush, children in lanes, kite sellers emerge |
| **Golden Hour (18–20)** | Closing | Shutters half-closed, goods brought inside, oil lamps lit |
| **Night (20–24)** | Closed | All shutters closed, occasional lamp glow through cracks, cats patrol |

### 12.11 Desert Wind and Sand Particles

**Continuous system, always active.**

- **Wind direction:** Predominantly west-to-east (Rajasthan's prevailing wind)
- **Speed:** 0.5–2 voxels/sec depending on time (strongest at noon)
- **Sand particles:** `#C4A060` 1x1 voxels, max 50 visible at once
- **Trajectory:** Parabolic arcs, launch from desert floor (X < 100), rise 3–8 voxels, land 20–40 voxels east
- **Accumulation effect:** Desert-facing walls (west of buildings) accumulate sand tint: `#C4A06020` overlay on bottom 3 voxels
- **Tree sway:** `#4A6B4A` tree canopies offset ±0.5 voxels in wind direction
- **Flag/kite interaction:** Festival kites angle with wind, pennants at forts stream east

### 12.12 Nighttime: Jaipur Lit at Night

**Pink walls glow warm under artificial lighting.**

| Light Source | Color | Radius | Placement |
|---|---|---|---|
| **Streetlamps** | `#FFE0A0` warm yellow | 6 voxels | Every 12 voxels on main avenues |
| **Shop lamps** | `#FFD080` amber | 4 voxels | Inside open shops through doorway |
| **Temple oil lamps** | `#FF9030` orange | 3 voxels | Along temple steps and gates |
| **Palace uplights** | `#FFE0C0` warm white | 8 voxels | Ground-level, aimed at Hawa Mahal, City Palace facades |
| **Lake reflection** | `#FFE0C080` warm | - | Jal Mahal lamps reflected on water |

**Night palette shift:**
- Pink walls: `#D4836A` → `#7A4A3A` (muted mauve under moonlight)
- Lit sections of pink walls: `#E89878` (where uplights hit)
- Cream walls: `#F0E0C8` → `#C0B8A8` (grey-cool)
- Moonlight direction: 45° from north, casting soft shadows south

### 12.13 Monsoon Relief System

**Trigger:** Random event, 8% chance during afternoon phase. Seasonal weighting: higher probability "simulated" during the build's afternoon cycle.

**Sequence:**
1. **Cloud build-up (1 min):** Sky gradient darkens: `#5B9BD5` → `#6A6A80` → `#4A4A60`
2. **Thunder:** Screen-shake effect (0.5-voxel displacement, 0.2 sec duration)
3. **Rain onset:** `#5A8AA080` vertical particle streaks, 200 concurrent, falling at 8 voxels/sec
4. **Rain intensity:** Peak at 2 min mark — visibility drops to 60 voxels, sky fully overcast `#4A4A60`
5. **Wet surfaces:** All horizontal surfaces gain `#5A8AA020` blue sheen
6. **Puddles:** Form on road surfaces (flat `#5A8AA040` patches, 2–4 voxels wide)
7. **Runoff:** Water flows along street gutters toward Dravyavati riverbed
8. **Post-rain (1 min):** Clouds break, `#D4A040` gold sunset appears, surfaces steam (white `#FFFFFF40` particles rising 2 voxels)
9. **Greenery response:** All `#4A6B4A` vegetation shifts to `#5A8B5A` (brighter green) for 10 minutes post-rain
10. **Duration:** 3–5 real minutes total

---

## 13. VEGETATION AND NATURAL ELEMENTS

### 13.1 Tree Types

| Species | Height | Canopy | Color | Placement |
|---------|--------|--------|-------|-----------|
| **Neem** | 8–12 | Spherical, 6 radius | `#4A6B4A` | Streets, courtyards |
| **Pipal** | 10–15 | Heart-shaped leaves, 8 radius | `#3A7B3A` | Temples, gardens |
| **Khejri** (desert) | 5–7 | Sparse, 4 radius | `#6A8B5A` | Desert edge, scattered |
| **Gulmohar** | 8–10 | Spread 6, red flowers | `#4A6B4A` + `#E03030` blooms | Gardens, Ram Niwas |
| **Bougainvillea** | 3–5 | Vine spread 4 | `#E03030`, `#D080D0`, `#F0D020` | Wall tops, havelis |

**Generation rules:**
- Courtyards: 1–2 trees (neem or pipal) in corners
- Main avenues: neem trees every 16 voxels
- Gardens (sector 8): dense grove, 50+ trees
- Desert edge: sparse khejri, 1 per 20x20 voxel area
- Wall tops: bougainvillea cascading down, `#E03030` flowers

### 13.2 Gardens

**Ram Niwas Garden (Sector 8):**
- Central park: 40x40 voxels
- Geometric Mughal garden layout
- 4 quadrants divided by water channels (2 wide, `#5A8AA0`)
- Each quadrant: `#4A6B4A` lawn + flower beds (`#E03030`, `#F0D020`, `#D080D0`)
- Central pavilion: 8x8, 2 stories, `#F0E8D8` marble, open sides
- Rose garden: 15x15 area, `#C83030` rose bushes (1x1x1, dense)
- Aviary: wire mesh structure (10x10x6), birds inside (1x1 colored dots)

### 13.3 Desert Flora

| Plant | Size | Color | Density |
|-------|------|-------|---------|
| **Kair** (cactus) | 2x2x3 | `#4A6B4A` + `#C4A060` | Scattered, desert edge |
| **Babul** (thorny) | 3x3x5 | `#6A8B5A` | Desert margin |
| **Desert grass** | 1x1x1 | `#C4A060` | Ground cover, desert floor |
| **Date palm** | 2x2x12 | `#6A7B4A` trunk, `#4A6B4A` fronds | Lake edges, oases |

---

## 14. CULTURAL DETAILS AND FESTIVAL SYSTEMS

### 14.1 Persistent Cultural Elements

#### Rangoli (threshold art)
- At every haveli entrance and temple gate
- 3x3 to 5x5 pixel art on ground
- Colors: `#F0D020`, `#E03030`, `#4A6B4A`, `#F0E8D8`
- Patterns: geometric, floral, peacock
- Refreshed every 12 real minutes (simulating daily tradition)

#### Toran (door garlands)
- Above every arched doorway: 1-voxel-deep, door-width strip
- `#F0D020` marigold + `#4A6B4A` mango leaves
- Present year-round (not festival-only)

#### Stepwell patterns
- 2 stepwells in the build (sectors 4, 9)
- Descending geometric staircase: 15 steps, alternating `#E8C8A0` and `#D4836A`
- Water at bottom: `#5A8AA0`, 3 voxels deep

### 14.2 Festival Events (random cycling, 1 per 30 real minutes)

#### Diwali (Festival of Lights)
- **Trigger:** 15% chance per cycle
- **Duration:** 5 real minutes
- **Effects:**
  - Every window: `#FFD080` oil lamp (1x1, warm glow radius 3)
  - Rangoli: extra-dense, 2x normal frequency
  - Sky: `#1A1030` (night required), but illuminated by thousands of lamps
  - Fireworks: 10–20 bursts per minute, random position Y=60–90, colors: `#E03030`, `#F0D020`, `#3060D0`, `#30A040`
  - NPCs: extra pedestrians, festive clothes, sweets shops display extra goods

#### Holi (Festival of Colors)
- **Trigger:** 10% chance per cycle, must be morning phase
- **Duration:** 4 real minutes
- **Effects:**
  - NPCs: color-splashed — random body colors instead of normal clothing
  - Ground: color powder (`#E03030`, `#F0D020`, `#3060D0`, `#30A040`, `#D080D0`) scattered on streets
  - Water: colored water in fountains and buckets
  - Buildings: lower walls get color splash overlay (random, fades over duration)

#### Makar Sankranti (Kite Festival)
- This is the kite system described in 12.6, with enhanced parameters:
  - Kite count: 500–800 (double normal)
  - Duration: 6 real minutes
  - Ground level: kite workshops display extra stock
  - "Kai po che!" zone: competitive flying, more cut kites (15%)

#### Elephant Festival
- **Trigger:** 5% chance per cycle
- **Duration:** 3 real minutes
- **Effects:**
  - 5 decorated elephants on main avenue
  - Elephants: 3x2x4 voxels, `#8B7355` base with `#E89030` + `#D4A040` ornamental cloth
  - Howdah (seat): 2x2x2, `#D4A040` gold trim
  - NPCs: crowds line avenue, extra density
  - Route: main N-S avenue, moving south to north

---

## 15. NIGHT CYCLE AND ATMOSPHERE

### 15.1 Night Mode Activation

Night begins at real minute 21 and lasts until minute 0 (3 real minutes).

### 15.2 Star Field

- 200–300 star voxels placed at Y=115–120 (sky dome)
- Color: `#FFFFFF` with 20% chance of `#FFE0A0` (warm star)
- Twinkle: random brightness oscillation (2-second cycle)
- Milky Way band: diagonal strip of higher-density stars across sky

### 15.3 Moon

- 5x5 cross-section circle at Y=118, positioned north of center
- Color: `#F0E8D8` (warm white)
- Phase changes every 6 real minutes (new, crescent, half, full)
- Moonlight direction: 45° from north, affects shadow casting

### 15.4 Night Soundscape Markers (visual indicators)

| Source | Visual | Location |
|---|---|---|
| **Cricket fields** | Subtle `#4A6B4A` grass flicker (particle) | Desert edge, gardens |
| **Dog rest spots** | 2–3 sleeping dogs (`#8B7355`) curled on warm sidewalks | Bazaar streets |
| **Cat patrols** | 4–6 cats (`#8B7355` or `#F0E8D8`) slinking along walls | Temple compounds |
| **Owl perches** | 1x1 `#8B7355` on fort wall crenellations, occasional head-turn | Nahargarh, Amber |

### 15.5 Jaipur Pink at Night

The city's signature color shifts under moonlight:

| Condition | Pink Color | Effect |
|---|---|---|
| **Moonlit face** | `#9A6A52` | Cool-warm muted pink |
| **Shadow face** | `#6A3A2A` | Deep brown-pink |
| **Streetlit face** | `#C88868` | Warm revived pink |
| **Dawn face** | `#D4836A` | Full Jaipur pink returns |

---

## 16. TECHNICAL IMPLEMENTATION NOTES

### 16.1 Voxel Budget

| Category | Estimated Voxels | % of Total |
|----------|-----------------|------------|
| **Terrain** | 1,200,000 | 11.1% |
| **Landmarks (7)** | 800,000 | 7.4% |
| **Residential/commercial buildings** | 2,000,000 | 18.5% |
| **Streets and paths** | 600,000 | 5.6% |
| **Vegetation** | 400,000 | 3.7% |
| **Water (lake, fountains)** | 100,000 | 0.9% |
| **Empty space (air)** | 5,790,000 | 53.7% |
| **Total solid voxels** | 5,100,000 | 46.3% |
| **Total grid** | 10,800,000 | 100% |

### 16.2 LOD (Level of Detail) Zones

| Distance from Camera | LOD Level | Rendering |
|---|---|---|
| 0–30 voxels | Full | All details, jali screens, individual NPCs |
| 30–80 voxels | High | Building details, simplified jali (solid blocks), merged NPC groups |
| 80–150 voxels | Medium | Building shells only, no interior detail, tree blobs |
| 150–250 voxels | Low | Silhouettes + color only, merged structures |
| 250–300 voxels | Haze | Dust-colored blocks only, merged into city mass |

### 16.3 Procedural Seed

A single 64-bit seed controls all procedural generation:
- Building placement and variation
- Henna pattern selection
- Turban color distribution
- Kite positions and colors
- Dust particle trajectories
- Festival timing (weighted random)
- Cow/monkey initial positions

Changing the seed produces a visually distinct but structurally identical Jaipur.

### 16.4 Build Order

| Phase | What | Dependencies |
|---|---|---|
| **1. Terrain** | Desert plain, hills, riverbed, lake | None |
| **2. Road grid** | Nine sectors, avenues | Terrain |
| **3. Landmarks** | All 7, from terrain-anchored positions | Terrain + grid |
| **4. Residential fill** | Havelis and shops in sectors | Grid |
| **5. Vegetation** | Trees, gardens, desert flora | Buildings |
| **6. Water** | Lake, fountains, channels | Terrain + landmarks |
| **7. Cultural details** | Henna, rangoli, torans, signage | Buildings |
| **8. Lighting** | Streetlamps, temple lamps, palace uplights | All static |
| **9. Procedural systems** | NPCs, animals, particles, weather | All static |

### 16.5 Memory and Performance Targets

| Metric | Target |
|---|---|
| **Voxels rendered per frame** | < 500,000 (with LOD + culling) |
| **Chunk size** | 16x16x16 voxels |
| **Loaded chunks** | ~500 (camera-centric, 80-voxel radius) |
| **Procedural tick rate** | 10 Hz (NPCs, particles, weather) |
| **Time-of-day update** | 1 Hz (color shifts, shadows) |
| **Target framerate** | 30 FPS |

---

## 17. COMPLETE BUILD SPECIFICATION

### 17.1 Landmark Position Summary

| # | Landmark | X Range | Z Range | Y Range | Footprint |
|---|---|---|---|---|---|
| 1 | Hawa Mahal | 88–110 | 190–198 | 4–48 | 22x8x44 |
| 2 | Amber Fort | 200–280 | 100–160 | 12–72 | 80x60x60 |
| 3 | City Palace | 68–123 | 110–155 | 4–40 | 55x45x36 |
| 4 | Jantar Mantar | 145–180 | 110–145 | 4–34 | 35x35x30 |
| 5 | Nahargarh Fort | 230–290 | 120–160 | 48–73 | 60x40x25 |
| 6 | Johari Bazaar | 10–50 | 125–150 | 4–14 | 40x25x10 |
| 7 | Jal Mahal | 170–200 | 185–205 | 0–22 | 30x20x22 |

### 17.2 Palette Quick Reference

| Name | Hex | Primary Use |
|---|---|---|
| Jaipur Pink | `#D4836A` | Walls, facades |
| Deep Pink | `#C47050` | Trim, shadows |
| Sandstone | `#E8C8A0` | Fort walls, temples |
| Cream Stucco | `#F0E0C8` | Plaster, upper stories |
| Desert Brown | `#8B7355` | Ground, earth, wood |
| Golden Sand | `#C4A060` | Desert floor, sandstone |
| Garden Green | `#4A6B4A` | Vegetation |
| Marble White | `#F0E8D8` | Marble floors, columns |
| Blue Accent | `#2060A0` | Doors, shutters, tiles |
| Gold Accent | `#D4A040` | Finials, jewelry, trim |

---

*Plan authored by the Chief Architect of Jaipur. Every voxel placed with intent. The Pink City endures.*
