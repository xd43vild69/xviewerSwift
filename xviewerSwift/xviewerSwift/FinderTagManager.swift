import SwiftUI
import AppKit

/// Representa los 7 colores nativos de etiqueta (Tag) que utiliza Finder en macOS.
public enum FinderColor: Int, CaseIterable, Identifiable, Codable {
    case gray = 1
    case green = 2
    case purple = 3
    case blue = 4
    case yellow = 5
    case red = 6
    case orange = 7

    public var id: Int { rawValue }

    public var localizedName: String {
        switch self {
        case .gray: return "Gris"
        case .green: return "Verde"
        case .purple: return "Púrpura"
        case .blue: return "Azul"
        case .yellow: return "Amarillo"
        case .red: return "Rojo"
        case .orange: return "Naranja"
        }
    }

    public var color: Color {
        switch self {
        case .gray: return Color(nsColor: .systemGray)
        case .green: return Color(nsColor: .systemGreen)
        case .purple: return Color(nsColor: .systemPurple)
        case .blue: return Color(nsColor: .systemBlue)
        case .yellow: return Color(nsColor: .systemYellow)
        case .red: return Color(nsColor: .systemRed)
        case .orange: return Color(nsColor: .systemOrange)
        }
    }

    /// Nombre de tag oficial utilizado por Finder (e.g. "Rojo\n6" o "Red\n6").
    public var tagRepresentation: String {
        "\(localizedName)\n\(rawValue)"
    }

    /// Determina el `FinderColor` a partir de cualquier string de tag que devuelva macOS.
    public static func from(tagString: String) -> FinderColor? {
        let trimmed = tagString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. Si contiene el sufijo de color de Finder "\n<number>"
        if let newlineIndex = trimmed.firstIndex(of: "\n") {
            let colorPart = trimmed[trimmed.index(after: newlineIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = Int(colorPart), let color = FinderColor(rawValue: id) {
                return color
            }
        }
        
        // 2. Si el tag es directamente el nombre del color (en inglés o español)
        let lower = trimmed.lowercased()
        switch lower {
        case "gray", "gris": return .gray
        case "green", "verde": return .green
        case "purple", "púrpura", "purpura", "violet": return .purple
        case "blue", "azul": return .blue
        case "yellow", "amarillo": return .yellow
        case "red", "rojo": return .red
        case "orange", "naranja": return .orange
        default: return nil
        }
    }

    /// Extrae el primer color encontrado en un arreglo de tags de macOS.
    public static func from(tags: [String]?) -> FinderColor? {
        guard let tags = tags, !tags.isEmpty else { return nil }
        for tag in tags {
            if let color = FinderColor.from(tagString: tag) {
                return color
            }
        }
        return nil
    }
}

public struct FinderTagManager {

    /// Lee el color de Finder asignado a la URL dada.
    public static func tagColor(for url: URL) -> FinderColor? {
        guard let values = try? url.resourceValues(forKeys: [.tagNamesKey]),
              let tags = values.tagNames else {
            return nil
        }
        return FinderColor.from(tags: tags)
    }

    /// Asigna o elimina el color de tag de Finder en una URL dada.
    /// Si `color` es nil, se remueven los tags de color existentes preservando posibles tags sin color.
    public static func setTagColor(_ color: FinderColor?, for url: URL) throws {
        let currentTags = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        var remainingTags = currentTags.filter { FinderColor.from(tagString: $0) == nil }
        
        if let newColor = color {
            remainingTags.append(newColor.tagRepresentation)
        }
        
        let nsURL = url as NSURL
        try nsURL.setResourceValue(remainingTags as NSArray, forKey: .tagNamesKey)
    }
}
