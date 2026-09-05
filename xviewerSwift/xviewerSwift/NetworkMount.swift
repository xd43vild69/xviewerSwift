//
//  NetworkMount.swift
//  xviewerSwift
//
//  Monta volúmenes de red (SMB/AFP/NFS) usando NetFS, replicando el
//  comportamiento de "Conectarse al servidor" (⌘K) de Finder.
//

import Foundation
import Darwin

enum NetworkMount {

    /// Devuelve todos los volúmenes de red montados actualmente en el sistema (SMB, AFP, NFS, etc.).
    static func currentMountedNetworkVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeNameKey, .volumeURLKey]
        guard let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return []
        }

        return mounted.filter { url in
            if let rv = try? url.resourceValues(forKeys: Set(keys)),
               let isLocal = rv.volumeIsLocal, !isLocal {
                return true
            }
            var stat = statfs()
            if statfs(url.path, &stat) == 0 {
                let fsType = withUnsafePointer(to: &stat.f_fstypename) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
                }
                return (stat.f_flags & UInt32(MNT_LOCAL)) == 0 || fsType == "smbfs" || fsType == "afpfs" || fsType == "nfs"
            }
            return false
        }
    }

    /// Devuelve todos los discos físicos/externos o imágenes montadas en el sistema (excluyendo el disco raíz / y volúmenes de red).
    static func currentMountedLocalDisks() -> [URL] {
        let keys: [URLResourceKey] = [
            .volumeIsLocalKey,
            .volumeNameKey,
            .volumeURLKey,
            .volumeIsRootFileSystemKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey
        ]
        guard let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return []
        }

        let networkVolumes = Set(currentMountedNetworkVolumes().map { $0.standardizedFileURL.path })

        return mounted.filter { url in
            let path = url.standardizedFileURL.path
            // 1. Excluir el volumen raíz del sistema "/"
            if path == "/" { return false }
            // 2. Excluir volúmenes del sistema interno de macOS (/System/Volumes/...)
            if path.hasPrefix("/System/Volumes") { return false }
            // 3. Excluir volúmenes de desarrollo/simulador
            if path.hasPrefix("/Library/Developer") { return false }
            // 4. Excluir volúmenes ya identificados como de red
            if networkVolumes.contains(path) { return false }

            // 5. Verificar con statfs que no sea un volumen de red
            var stat = statfs()
            if statfs(url.path, &stat) == 0 {
                let fsType = withUnsafePointer(to: &stat.f_fstypename) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
                }
                if fsType == "smbfs" || fsType == "afpfs" || fsType == "nfs" || fsType == "autofs" || fsType == "devfs" {
                    return false
                }
                if (stat.f_flags & UInt32(MNT_LOCAL)) == 0 {
                    return false
                }
                // Si está montado en /Volumes/* o es removible/eyectable/externo, es un disco de usuario
                if path.hasPrefix("/Volumes/") {
                    return true
                }
            }

            if let rv = try? url.resourceValues(forKeys: Set(keys)) {
                if rv.volumeIsRootFileSystem == true { return false }
                if rv.volumeIsRemovable == true || rv.volumeIsEjectable == true || rv.volumeIsInternal == false {
                    return true
                }
            }

            return false
        }
    }

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
