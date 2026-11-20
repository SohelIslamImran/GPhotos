import Foundation

public struct SearchCategory: Sendable, Equatable, Identifiable {
  public var id: String { label }
  public let label: String
  public let displayName: String
  public let count: Int
  public let sampleID: String
}

public struct SearchSuggestion: Sendable, Equatable, Identifiable {
  public enum Kind: String, Sendable { case person, category, metadata, text }
  public var id: String { kind.rawValue + ":" + query }
  public let kind: Kind
  public let title: String
  public let query: String
  public let count: Int
}

/// Keep broad visual attributes searchable only when they describe a useful subject.
/// Vision returns its ancestors too; retaining all accepted observations keeps animal
/// searchable alongside dog without inventing ancestry for ambiguous labels.
enum SearchVocabulary {
  static let generic: Set<String> = [
    "structure", "material", "indoor", "outdoor", "person", "human",
    "textile", "fabric", "pattern", "object", "thing", "physical_entity", "entity",
    "artifact", "whole", "natural_object", "organism", "living_thing", "body_part",
    "clothing", "fashion", "design", "close_up", "abstract", "background", "nobody",
  ]
  static let categoryExcluded: Set<String> = generic.union([
    "animal", "mammal", "vertebrate", "domestic_pet", "water_body", "people", "adult", "land", "sky", "blue_sky", "liquid",
    "water", "daytime", "plant", "vegetation", "foliage", "conveyance", "vehicle", "furniture", "interior_room",
    "housewares", "container", "tool", "machine", "consumer_electronics", "media", "recreation", "decoration",
    "wood_processed", "wood_natural", "optical_equipment", "portal", "utensil", "tableware", "headgear",
    "sports_equipment", "raw_glass", "timepiece", "footwear", "celestial_body", "ungulates", "arthropods", "brick", "light",
  ])
  static let aliases = [
    "canine": "dog", "canid": "dog", "feline": "cat", "automobile": "car", "motorcar": "car",
    "ocean": "sea_ocean", "sea": "sea_ocean", "seashore": "beach", "shore": "beach",
    "flower": "flowers", "blossom": "flowers", "tree": "trees", "mountain": "mountains",
  ]
  static let names = [
    "sea_ocean": "Sea & Ocean", "dog": "Dogs", "cat": "Cats", "car": "Cars",
    "beach": "Beaches", "flowers": "Flowers", "trees": "Trees", "mountains": "Mountains",
    "food": "Food", "animal": "Animals", "bird": "Birds", "sunset_sunrise": "Sunsets & Sunrises",
    "water_body": "Water", "potted_plant": "Plants", "domestic_pet": "Pets",
  ]
  /// What people type for the labels Vision gives, which are narrower and often not the
  /// everyday word: a mountain photo is usually labelled "hill". Keys are singular; values
  /// are stored label names. Matches through these rank below the typed word itself.
  static let related: [String: [String]] = [
    "mountain": ["mountains", "hill", "cliff", "canyon", "glacier", "volcano"],
    "hill": ["hill", "mountains"], "cliff": ["cliff", "canyon", "rocks"], "rock": ["rocks", "cliff"],
    "valley": ["hill", "mountains", "canyon"], "peak": ["mountains", "hill"],
    "beach": ["beach", "shore", "sand", "sandcastle"], "shore": ["shore", "beach", "sea_ocean"],
    "coast": ["shore", "beach", "sea_ocean", "cliff"], "seaside": ["shore", "beach", "sea_ocean"],
    "sea": ["sea_ocean", "shore"], "ocean": ["sea_ocean", "shore"], "wave": ["sea_ocean", "surfing"],
    "water": ["water", "sea_ocean", "lake", "river", "waterfall", "creek", "pool"],
    "lake": ["lake"], "pond": ["lake"], "river": ["river", "creek", "waterways"], "stream": ["creek", "river"],
    "snow": ["snow", "blizzard", "frozen", "ice", "glacier", "snowman"], "ice": ["ice", "frozen", "glacier", "iceberg"],
    "winter": ["snow", "frozen", "winter_sport"],
    "sunset": ["sunset_sunrise"], "sunrise": ["sunset_sunrise"], "dusk": ["sunset_sunrise"], "dawn": ["sunset_sunrise"],
    "sky": ["sky", "blue_sky", "cloudy", "night_sky"], "cloud": ["cloudy"], "night": ["night_sky", "moon", "fireworks"],
    "star": ["night_sky"], "sun": ["sun", "sunset_sunrise"], "fog": ["haze"], "mist": ["haze"],
    "storm": ["storm", "thunderstorm", "lightning"],
    "flower": ["flowers", "blossom", "bouquet", "flower_arrangement", "rose", "tulip", "sunflower", "daisy", "orchid", "lily"],
    "tree": ["trees", "forest", "palm_tree", "evergreen", "maple_tree", "oak_tree"],
    "forest": ["forest", "jungle", "trees"], "wood": ["forest", "trees", "wood_natural"], "jungle": ["jungle", "forest"],
    "plant": ["plant", "foliage", "vegetation", "decorative_plant", "ferns", "shrub"], "leaf": ["foliage"],
    "leave": ["foliage"], "garden": ["garden", "flowers", "greenhouse"], "park": ["park", "playground"],
    "grass": ["grass"], "field": ["grass", "rice_field", "agriculture", "farm"], "farm": ["farm", "agriculture", "barn"],
    "nature": ["land", "forest", "trees", "mountains", "hill", "river", "lake", "waterfall"],
    "landscape": ["land", "mountains", "hill", "forest", "lake", "desert"],
    "desert": ["desert", "sand_dune"], "sand": ["sand", "sand_dune", "beach"],
    "city": ["cityscape", "skyscraper", "building", "street"], "town": ["cityscape", "street", "building"],
    "building": ["building", "skyscraper", "house_single", "tower"], "skyline": ["cityscape", "skyscraper"],
    "street": ["street", "road", "sidewalk", "crosswalk"], "road": ["road", "street", "dirt_road"],
    "house": ["house_single", "domicile"], "home": ["house_single", "domicile", "living_room"],
    "car": ["car", "suv", "sportscar", "convertible", "jeep", "van", "limousine"], "vehicle": ["vehicle", "car"],
    "bike": ["bicycle", "cycling", "motorcycle"], "bicycle": ["bicycle", "cycling"],
    "motorbike": ["motorcycle"], "train": ["train", "train_real", "railroad", "train_station"],
    "plane": ["airplane", "aircraft", "airport"], "airplane": ["airplane", "aircraft"], "flight": ["airplane", "airport"],
    "boat": ["boat", "watercraft", "sailboat", "rowboat", "yacht"], "ship": ["cruise_ship", "watercraft", "boat", "warship"],
    "puppy": ["dog"], "kitten": ["kitten", "cat"], "pet": ["dog", "cat"],
    "person": ["people"], "people": ["people"], "human": ["people"], "selfie": ["people"], "portrait": ["people"],
    "man": ["people", "adult"], "woman": ["people", "adult"], "men": ["people", "adult"], "women": ["people", "adult"],
    "kid": ["child", "baby", "teen"], "child": ["child", "baby"], "children": ["child", "baby"], "boy": ["child", "people"],
    "girl": ["child", "people"], "infant": ["baby"], "crowd": ["crowd", "people"], "group": ["people", "crowd"],
    "wedding": ["wedding", "bride", "groom", "wedding_dress", "wedding_cake", "bridesmaid"],
    "birthday": ["birthday_cake", "celebration", "balloon"], "party": ["celebration", "concert", "nightclub"],
    "christmas": ["christmas_tree", "christmas_decoration", "santa_claus"],
    "meal": ["food"], "lunch": ["food"], "dinner": ["food"], "breakfast": ["food"], "snack": ["food"],
    "drink": ["drink"], "tea": ["tea_drink"], "cake": ["cake", "birthday_cake", "cupcake", "dessert"],
    "burger": ["hamburger"], "noodle": ["ramen", "pasta", "spaghetti"], "sweet": ["dessert", "candy"],
    "document": ["document", "printed_page", "receipt", "handwriting", "newspaper"],
    "paper": ["document", "printed_page", "newspaper"], "receipt": ["receipt"], "bill": ["receipt"],
    "invoice": ["receipt", "document"], "note": ["handwriting", "sticky_note", "document"],
    "text": ["printed_page", "handwriting", "document"], "writing": ["handwriting"],
    "computer": ["computer", "laptop", "computer_monitor"], "tv": ["television"], "screen": ["computer_monitor", "television"],
    "sport": ["sport"], "game": ["sport", "games", "videogame"], "football": ["soccer", "football"],
    "cricket": ["cricket_sport"], "swim": ["swimming", "pool"], "swimming": ["swimming", "pool"], "pool": ["pool"],
    "gym": ["workout", "health_club"], "workout": ["workout", "health_club"],
    "fire": ["fire", "flame", "fireplace", "embers"], "firework": ["fireworks", "pyrotechnics", "sparkler"],
    "art": ["art", "painting", "illustrations", "graffiti"], "drawing": ["illustrations", "art"],
    "toy": ["toy", "stuffed_animals", "doll"], "shoe": ["shoes", "footwear", "sneaker"],
    "glasses": ["eyeglasses", "sunglasses"], "room": ["interior_room", "living_room", "bedroom"],
    "office": ["desk", "cubicle", "conference"], "cafe": ["restaurant", "coffee"], "shop": ["interior_shop", "storefront"],
    "store": ["interior_shop", "storefront"], "market": ["interior_shop", "storefront"], "school": ["classroom"],
    "temple": ["monument", "dome", "tower", "statue"], "mosque": ["dome", "monument", "tower"],
    "church": ["monument", "tower", "stained_glass"], "monument": ["monument", "statue", "ruins", "obelisk"],
    "camp": ["camping", "tent"], "hike": ["hiking", "trail"], "trek": ["hiking", "trail"],
    "travel": ["luggage", "suitcase", "airport", "airplane"], "trip": ["luggage", "suitcase", "airport"],
    "money": ["money", "currency", "coin"], "cash": ["money", "currency"], "card": ["credit_card", "gift_card"],
    "music": ["music", "musical_instrument", "concert"], "dance": ["dancing"], "show": ["performance", "concert"],
  ]

  /// Other forms of an English word ("mountains" for "mountain" and back), so a plural
  /// finds the label and the label's plural finds it too.
  static func forms(_ word: String) -> [String] {
    guard word.count > 2, word.allSatisfy({ $0.isASCII && $0.isLetter }) else { return [] }
    var forms: [String] = []
    if word.hasSuffix("ies"), word.count > 4 {
      forms.append(String(word.dropLast(3)) + "y")
    } else if word.hasSuffix("es"), word.count > 3 {
      forms += [String(word.dropLast(2)), String(word.dropLast())]
    } else if word.hasSuffix("s"), !word.hasSuffix("ss"), word.count > 3 {
      forms.append(String(word.dropLast()))
    } else {
      let endsInConsonantY = word.hasSuffix("y") && !"aeiou".contains(word.dropLast().last ?? "a")
      forms.append(endsInConsonantY ? String(word.dropLast()) + "ies" : word + "s")
    }
    return forms
  }

  static func canonical(_ label: String) -> String { aliases[label.lowercased()] ?? label.lowercased() }
  static func displayName(_ label: String) -> String {
    names[label] ?? label.replacingOccurrences(of: "_", with: " ").capitalized
  }
  static func tokens(_ text: String) -> [String] {
    text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
  }

  /// Written without spaces between words (Chinese, Japanese, Thai, Lao, Khmer, Myanmar):
  /// the index keeps a whole run as one token, so these words match as prefixes.
  static func isUnspaced(_ word: String) -> Bool {
    word.unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
        0xF900...0xFAFF, 0x20000...0x2FA1F:
        true
      default: false
      }
    }
  }

  /// A word as the index's tokenizer stores it (unicode61 with remove_diacritics 2):
  /// lowercased, with diacritics removed from Latin letters only, so other scripts' marks
  /// (Bengali vowel signs, for example) stay part of the word.
  static func folded(_ word: String) -> String {
    var scalars = String.UnicodeScalarView()
    var lastBaseIsLatin = false
    for scalar in word.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
      if scalar.properties.generalCategory == .nonspacingMark {
        if !lastBaseIsLatin { scalars.append(scalar) }
        continue
      }
      lastBaseIsLatin = (0x41...0x24F).contains(scalar.value) || (0x1E00...0x1EFF).contains(scalar.value)
      scalars.append(scalar)
    }
    return String(scalars).precomposedStringWithCanonicalMapping
  }
}
