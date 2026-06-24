//
//  NetworkMount.swift
//  xviewerSwift
//
//  Monta volúmenes de red (SMB/AFP/NFS) usando NetFS, replicando el
//  comportamiento de "Conectarse al servidor" (⌘K) de Finder.
//

import Foundation

enum NetworkMount {

    enum MountError: LocalizedError {
        case invalidURL
        case noMountPoint
        case netfs(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidURL:        return "URL de servidor inválida"
            case .noMountPoint:      return "No se obtuvo el punto de montaje"
            case .netfs(let code):   return "Fallo al montar (código \(code))"
            }
        }
    }

    /// Monta una URL de red (p. ej. `smb://host/share`).
    /// Si ya está montada, devuelve su ruta local sin volver a montar.
    /// Usa credenciales guardadas en el Llavero y muestra el diálogo de
    /// autenticación del sistema si hace falta.
    /// - Parameter completion: se invoca **en el hilo principal** con la
    ///   ruta local (`/Volumes/...`) o un error.
    static func mount(_ urlString: String,
                      completion: @escaping (Result<URL, Error>) -> Void) {

        guard let url = URL(string: urlString) else {
            completion(.failure(MountError.invalidURL))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // Si ya está montado, reutiliza el punto de montaje existente.
            if let existing = existingMountPoint(for: url) {
                DispatchQueue.main.async { completion(.success(existing)) }
                return
            }

            // Permite que el sistema muestre el diálogo de autenticación
            // si las credenciales del Llavero no bastan.
            let openOptions = NSMutableDictionary()
            openOptions[kNAUIOptionKey] = kNAUIOptionAllowUI

            var mountpoints: Unmanaged<CFArray>?
            let status = NetFSMountURLSync(
                url as CFURL,
                nil,                                   // montar bajo /Volumes
                nil,                                   // usuario (Llavero / invitado / diálogo)
                nil,                                   // contraseña
                openOptions as CFMutableDictionary,    // open options
                nil,                                   // mount options
                &mountpoints
            )

            DispatchQueue.main.async {
                guard status == 0 else {
                    completion(.failure(MountError.netfs(status)))
                    return
                }
                if let paths = mountpoints?.takeRetainedValue() as? [String],
                   let first = paths.first {
                    completion(.success(URL(fileURLWithPath: first)))
                } else if let existing = existingMountPoint(for: url) {
                    completion(.success(existing))
                } else {
                    completion(.failure(MountError.noMountPoint))
                }
            }
        }
    }

    /// Devuelve la ruta local si el share ya está montado en `/Volumes`.
    private static func existingMountPoint(for url: URL) -> URL? {
        guard let share = url.path.split(separator: "/").last.map(String.init),
              !share.isEmpty else { return nil }
        let candidate = URL(fileURLWithPath: "/Volumes").appendingPathComponent(share)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}
