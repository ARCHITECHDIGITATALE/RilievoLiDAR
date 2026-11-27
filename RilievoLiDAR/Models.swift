import Foundation
import simd

// MARK: - Dati del progetto (salvati in project.json)

struct RoomRecord: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var file: String          // percorso relativo del JSON di RoomPlan
    var sessionID: UUID       // stanze della stessa sessione condividono le coordinate
    var date: Date
    var path: [Float]?        // percorso dell'operatore: x, y, z ripetuti (metri)
}

struct PhotoRecord: Codable, Identifiable, Hashable {
    var id: UUID
    var file: String          // percorso relativo della foto
    var thumbFile: String     // percorso relativo della miniatura
    var note: String
    var date: Date
    var position: [Float]     // posizione della camera x, y, z (metri)
    var source: String        // "stanze" oppure "mesh"
    var direction: [Float]?   // direzione di ripresa (avanti della fotocamera) x, y, z
    var target: [Float]?      // punto inquadrato al centro della foto x, y, z (se c'è la profondità)
    var width: Float?         // larghezza misurata scritta nella nota (metri)
    var height: Float?        // altezza misurata scritta nella nota (metri)
    var room: String?         // vano (es. Cucina)
    var level: String?        // piano (es. Terra, 1°)
}

struct MeshInfo: Codable, Hashable {
    var date: Date
    var keyframes: Int
    var faces: Int
    var texturedFaces: Int
    /// Mappe di profondità fuse nella ricostruzione (0 o nil = mesh di ARKit in tempo reale).
    var depthFrames: Int?
    /// Durata dell'elaborazione a fine scansione, in secondi.
    var processingSeconds: Double?
    /// Risoluzione delle texture rispetto alle foto (1 = piena risoluzione).
    var textureScale: Double?

    var sourceText: String {
        if let n = depthFrames, n > 0 { return "Ricostruita da \(n) mappe di profondità" }
        return "Mesh in tempo reale di ARKit"
    }
}

struct Project: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var created: Date
    var modified: Date
    var rooms: [RoomRecord]
    var photos: [PhotoRecord]
    var mesh: MeshInfo?

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.created = Date()
        self.modified = Date()
        self.rooms = []
        self.photos = []
        self.mesh = nil
    }
}

/// Fotogramma salvato durante la scansione mesh (foto + posa della camera).
struct KeyframeRecord: Codable {
    var index: Int
    var image: String          // relativo alla cartella export (es. foto/kf_0001.jpg)
    var depth: String?         // relativo alla cartella mesh (es. depth/kf_0001.bin)
    var width: Int
    var height: Int
    var depthWidth: Int
    var depthHeight: Int
    var intrinsics: [Float]    // matrice 3x3, colonna per colonna
    var transform: [Float]     // matrice 4x4 camera -> mondo, colonna per colonna
    var timestamp: Double
}

extension KeyframeRecord: Identifiable {
    var id: Int { index }
}

// MARK: - Utilità

struct ExportError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Fmt {
    /// Numero in metri con due decimali e virgola (es. 3,25)
    static func m(_ v: Float) -> String {
        String(format: "%.2f", v).replacingOccurrences(of: ".", with: ",")
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
}

extension simd_float4x4 {
    var floatArray: [Float] {
        [columns.0.x, columns.0.y, columns.0.z, columns.0.w,
         columns.1.x, columns.1.y, columns.1.z, columns.1.w,
         columns.2.x, columns.2.y, columns.2.z, columns.2.w,
         columns.3.x, columns.3.y, columns.3.z, columns.3.w]
    }

    init(floatArray a: [Float]) {
        self.init(columns: (SIMD4<Float>(a[0], a[1], a[2], a[3]),
                            SIMD4<Float>(a[4], a[5], a[6], a[7]),
                            SIMD4<Float>(a[8], a[9], a[10], a[11]),
                            SIMD4<Float>(a[12], a[13], a[14], a[15])))
    }

    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }
}

extension simd_float3x3 {
    var floatArray: [Float] {
        [columns.0.x, columns.0.y, columns.0.z,
         columns.1.x, columns.1.y, columns.1.z,
         columns.2.x, columns.2.y, columns.2.z]
    }
}
