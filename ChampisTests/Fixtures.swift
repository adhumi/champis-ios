import Foundation

/// Réponses d'API synthétiques, de la forme exacte de champis-api (routeurs `species`, `tiles`,
/// `weather`). Les espèces reprennent le gabarit de `species/boletus_edulis.json` ; les blocs
/// `terrain` sont omis, l'app ne les lit pas.
nonisolated enum Fixtures {
    static let paletteJSON = """
    {
      "version": 1,
      "thresholds": [
        { "min": 0.75, "label": "excellent", "fr": "Excellent", "hex": "#1B6B3A" },
        { "min": 0.55, "label": "bon", "fr": "Bon", "hex": "#4CA64C" },
        { "min": 0.35, "label": "moyen", "fr": "Moyen", "hex": "#E3C64B" },
        { "min": 0.15, "label": "faible", "fr": "Faible", "hex": "#E88A3C" },
        { "min": 0.0, "label": "tres_faible", "fr": "Très faible", "hex": "#B8402E" }
      ],
      "nodata_hex": "#00000000",
      "tile_encoding": { "channel": "luminance", "scale": 254, "nodata": 255 },
      "alt_encoding": { "channel": "luminance", "class_m": 300, "nodata": 255 }
    }
    """

    static func speciesJSON(id: String, group: (id: String, fr: String), fr: String, la: String) -> String {
        """
        {
          "id": "\(id)",
          "schema_version": 1,
          "group": { "id": "\(group.id)", "fr": "\(group.fr)" },
          "names": { "fr": "\(fr)", "la": "\(la)" },
          "phenology": {
            "season": { "start": "07-15", "end": "12-15" },
            "peak": { "start": "09-01", "end": "10-31" },
            "ramp_days": 30,
            "altitude_shift": { "reference_m": 300, "start_days_per_100m": -3, "end_days_per_100m": -3, "max_days": 30 }
          },
          "weather": {
            "temp_mean": { "window_days": 20, "c": { "min": 5, "opt_low": 10, "opt_high": 16, "max": 22 } },
            "rain": { "window_days": 28, "mm": { "min": 30, "opt_low": 60, "opt_high": 150, "max": 600 } },
            "trigger": { "event_mm": 20, "event_days": 3, "lag_days": { "min": 6, "opt_low": 10, "opt_high": 20, "max": 32 } },
            "soil_moisture_pct": { "min": 0.15, "opt_low": 0.4, "opt_high": 0.9, "max": 1.0 },
            "frost": { "tmin_c": -2, "nights": 2, "window_days": 7, "factor": 0.2 },
            "water_balance": { "window_days": 14, "moderate_mm": -25, "severe_mm": -45, "moderate_factor": 0.4, "severe_factor": 0.15 },
            "heat": { "tmax_c": 28, "days": 3, "window_days": 7, "factor": 0.5 },
            "memory": { "window_days": 90, "mm": { "min": 60, "opt_low": 120, "opt_high": 400, "max": 900 }, "floor": 0.3 },
            "persistence": { "days": 10 },
            "weights": { "temp": 0.3, "rain": 0.3, "trigger": 0.25, "soil_moisture": 0.15 }
          }
        }
        """
    }

    /// `GET /species` : deux cèpes et une girolle.
    static let catalogJSON = """
    {
      "scoring_version": "1.0.0",
      "species_hash": "af34c16e",
      "palette": \(paletteJSON),
      "species": {
        "boletus_edulis": \(speciesJSON(id: "boletus_edulis", group: ("cepes", "Cèpes"), fr: "Cèpe de Bordeaux", la: "Boletus edulis")),
        "boletus_aereus": \(speciesJSON(id: "boletus_aereus", group: ("cepes", "Cèpes"), fr: "Cèpe bronzé", la: "Boletus aereus")),
        "cantharellus_cibarius": \(speciesJSON(id: "cantharellus_cibarius", group: ("girolles", "Girolles"), fr: "Girolle", la: "Cantharellus cibarius"))
      }
    }
    """

    /// `GET /tiles` en mode proxy : URL relatives à l'API.
    static let manifestJSON = """
    {
      "configured": true,
      "mode": "proxy",
      "generated": "2026-10-30T03:00:00Z",
      "depts_by_hash": { "a1b2c3": ["25"] },
      "tiles": [
        {
          "kind": "T", "species": "boletus_edulis", "hash": "af34c16e", "scoring_version": "1.0.0", "depts_hash": "a1b2c3",
          "name": "T-boletus_edulis-af34c16e-p1.0.0-da1b2c3.pmtiles",
          "key": "tiles/T-boletus_edulis-af34c16e-p1.0.0-da1b2c3.pmtiles", "bytes": 123456,
          "url": "/tiles/T-boletus_edulis-af34c16e-p1.0.0-da1b2c3.pmtiles"
        },
        {
          "kind": "A", "class_m": 300, "depts_hash": "a1b2c3",
          "name": "A-300m-da1b2c3.pmtiles", "key": "tiles/A-300m-da1b2c3.pmtiles", "bytes": 4567,
          "url": "/tiles/A-300m-da1b2c3.pmtiles"
        }
      ]
    }
    """

    /// `GET /tiles` avec des jeux par département (champ `dept`) et le jeu France.
    static let manifestPerDeptJSON = """
    {
      "configured": true,
      "mode": "proxy",
      "generated": "2026-10-31T03:00:00Z",
      "depts_by_hash": { "a1b2c3": ["25", "39"], "222222": ["25"], "333333": ["39"] },
      "tiles": [
        { "kind": "T", "species": "boletus_edulis", "hash": "af34c16e", "scoring_version": "1.0.0", "depts_hash": "a1b2c3",
          "name": "T-boletus_edulis-af34c16e-p1.0.0-da1b2c3.pmtiles", "key": "tiles/x", "bytes": 5000, "url": "/tiles/T-boletus_edulis-af34c16e-p1.0.0-da1b2c3.pmtiles" },
        { "kind": "T", "species": "boletus_edulis", "hash": "af34c16e", "scoring_version": "1.0.0", "depts_hash": "222222", "dept": "25",
          "name": "T-boletus_edulis-af34c16e-p1.0.0-d222222.pmtiles", "key": "tiles/x", "bytes": 1000, "url": "/tiles/T-boletus_edulis-af34c16e-p1.0.0-d222222.pmtiles" },
        { "kind": "T", "species": "boletus_aereus", "hash": "af34c16e", "scoring_version": "1.0.0", "depts_hash": "222222", "dept": "25",
          "name": "T-boletus_aereus-af34c16e-p1.0.0-d222222.pmtiles", "key": "tiles/x", "bytes": 2000, "url": "/tiles/T-boletus_aereus-af34c16e-p1.0.0-d222222.pmtiles" },
        { "kind": "A", "class_m": 300, "depts_hash": "222222", "dept": "25",
          "name": "A-300m-d222222.pmtiles", "key": "tiles/x", "bytes": 300, "url": "/tiles/A-300m-d222222.pmtiles" },
        { "kind": "T", "species": "boletus_edulis", "hash": "af34c16e", "scoring_version": "1.0.0", "depts_hash": "333333", "dept": "39",
          "name": "T-boletus_edulis-af34c16e-p1.0.0-d333333.pmtiles", "key": "tiles/x", "bytes": 900, "url": "/tiles/T-boletus_edulis-af34c16e-p1.0.0-d333333.pmtiles" }
      ]
    }
    """

    /// `GET /weather/bbox` : une cellule à 47,0 N / 8,4 E (au centre de la tuile 6/33/22), deux
    /// classes d'altitude, deux jours pour le cèpe de Bordeaux, un pour le cèpe bronzé.
    static let weatherJSON = """
    {
      "today": "2026-10-30",
      "scoring_version": "1.0.0",
      "cells": [
        {
          "cell": { "id": "c_1", "lat": 47.0, "lon": 8.4, "alt_classes": [150.0, 450.0], "elevation_m": 620.0 },
          "stale": false,
          "species": {
            "boletus_edulis": [
              { "date": "2026-10-30", "by_alt": { "150": { "M": 0.5, "M_eff": 0.5, "phi": 1.0 }, "450": { "M": 0.9, "M_eff": 0.9, "phi": 1.0 } } },
              { "date": "2026-10-31", "by_alt": { "150": { "M": 0.6, "M_eff": 0.6, "phi": 1.0 }, "450": { "M": 0.6, "M_eff": 0.6, "phi": 1.0,
                "summary": ["pluie déclenchante il y a 12 jours", "sol bien humide", "pleine saison"], "trigger_days": 12 } } }
            ],
            "boletus_aereus": [
              { "date": "2026-10-30", "by_alt": { "150": { "M": 0.2, "M_eff": 0.2, "phi": 1.0 }, "450": { "M": 0.2, "M_eff": 0.2, "phi": 1.0 } } }
            ]
          }
        }
      ],
      "unavailable": ["c_9"],
      "retry_after": null
    }
    """

    /// `GET /departements` : deux départements, un groupe (max + leading) et ses espèces.
    static let departementsJSON = """
    {
      "today": "2026-10-30",
      "computed_at": "2026-10-30T03:12:00+00:00",
      "scoring_version": "1.0.0",
      "species_hash": "af34c16e",
      "departements": {
        "25": {
          "species": {
            "boletus_edulis": [
              { "date": "2026-10-30", "value": 0.62, "coverage": 0.9 },
              { "date": "2026-10-31", "value": null, "coverage": 0.0 }
            ],
            "boletus_aereus": [ { "date": "2026-10-30", "value": 0.3, "coverage": 0.9 } ]
          },
          "groups": {
            "cepes": [
              { "date": "2026-10-30", "value": 0.62, "leading": "boletus_edulis", "coverage": 0.9 },
              { "date": "2026-10-31", "value": null, "leading": null, "coverage": 0.0 }
            ]
          }
        },
        "39": {
          "species": { "boletus_edulis": [ { "date": "2026-10-30", "value": 0.2, "coverage": 0.5 } ] },
          "groups": { "cepes": [ { "date": "2026-10-30", "value": 0.2, "leading": "boletus_edulis", "coverage": 0.5 } ] }
        }
      }
    }
    """

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
