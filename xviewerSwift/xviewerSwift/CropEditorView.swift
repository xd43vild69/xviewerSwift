import SwiftUI
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// MARK: - Modelo de transformación

/// Proporciones seleccionables para el recorte.
enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, square, fourThree, sixteenNine, threeTwo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free: return "Libre"
        case .original: return "Original"
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .sixteenNine: return "16:9"
        case .threeTwo: return "3:2"
        }
    }

    /// Relación ancho/alto deseada, o nil si es libre.
    /// `imageAspect` es el ancho/alto de la imagen *sin rotar*.
    func ratio(imageAspect: CGFloat) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return imageAspect
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .sixteenNine: return 16.0 / 9.0
        case .threeTwo: return 3.0 / 2.0
        }
    }
}

/// Rotación aplicada a la imagen: pasos de 90° + ajuste fino continuo.
struct CropTransform: Equatable {
    var quarterTurns: Int = 0       // 0...3
    var fineAngle: Double = 0       // -45.0 ... 45.0
    var flipH: Bool = false

    var angle: Double { Double(quarterTurns) * 90.0 + fineAngle }
    var radians: CGFloat { CGFloat(angle * .pi / 180.0) }

    /// Bounding box de una imagen de tamaño `s` tras rotarla `angle` grados.
    func rotatedBounds(of s: CGSize) -> CGSize {
        let c = abs(cos(radians))
        let si = abs(sin(radians))
        return CGSize(width: s.width * c + s.height * si,
                      height: s.width * si + s.height * c)
    }
}

// MARK: - Geometría

/// Todo el trabajo se hace en "unidades de imagen": la imagen sin rotar mide
/// 1.0 de ancho y `aspectInverso` de alto. El rect de recorte vive en el
/// espacio del bounding box rotado, con origen arriba-izquierda (y hacia abajo).
enum CropGeometry {

    /// Convierte un punto del espacio del bounding box rotado al espacio de la imagen original.
    static func imagePoint(_ q: CGPoint, bounds: CGSize, image: CGSize, radians: CGFloat) -> CGPoint {
        let x = q.x - bounds.width / 2
        let y = q.y - bounds.height / 2
        let c = cos(radians), s = sin(radians)
        // Rotación inversa (-θ) en espacio y-abajo.
        let px = x * c + y * s
        let py = -x * s + y * c
        return CGPoint(x: px + image.width / 2, y: py + image.height / 2)
    }

    /// ¿Las 4 esquinas del rect caen dentro de la imagen original?
    static func isContained(_ rect: CGRect, bounds: CGSize, image: CGSize, radians: CGFloat) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        let eps: CGFloat = 1e-6
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)
        ]
        for corner in corners {
            let p = imagePoint(corner, bounds: bounds, image: image, radians: radians)
            if p.x < -eps || p.y < -eps || p.x > image.width + eps || p.y > image.height + eps {
                return false
            }
        }
        return true
    }

    /// Encoge el rect alrededor de su centro hasta que quepa dentro de la imagen rotada.
    /// Si su centro cae fuera de la imagen, reintenta desde el centro del bounding box.
    static func shrinkToFit(_ rect: CGRect, bounds: CGSize, image: CGSize, radians: CGFloat) -> CGRect {
        if isContained(rect, bounds: bounds, image: image, radians: radians) { return rect }

        func search(around center: CGPoint) -> CGRect? {
            let probe = CGRect(x: center.x - 0.0005, y: center.y - 0.0005, width: 0.001, height: 0.001)
            guard isContained(probe, bounds: bounds, image: image, radians: radians) else { return nil }
            var lo: CGFloat = 0, hi: CGFloat = 1
            for _ in 0..<26 {
                let mid = (lo + hi) / 2
                let candidate = CGRect(x: center.x - rect.width * mid / 2,
                                       y: center.y - rect.height * mid / 2,
                                       width: rect.width * mid,
                                       height: rect.height * mid)
                if isContained(candidate, bounds: bounds, image: image, radians: radians) { lo = mid } else { hi = mid }
            }
            return CGRect(x: center.x - rect.width * lo / 2,
                          y: center.y - rect.height * lo / 2,
                          width: rect.width * lo,
                          height: rect.height * lo)
        }

        if let fitted = search(around: CGPoint(x: rect.midX, y: rect.midY)) { return fitted }
        return search(around: CGPoint(x: bounds.width / 2, y: bounds.height / 2)) ?? rect
    }

    /// Rect máximo con la proporción dada, centrado en el bounding box.
    static func maximalRect(ratio: CGFloat?, bounds: CGSize, image: CGSize, radians: CGFloat) -> CGRect {
        let targetRatio = ratio ?? (bounds.width / bounds.height)
        var width = bounds.width
        var height = width / targetRatio
        if height > bounds.height {
            height = bounds.height
            width = height * targetRatio
        }
        let seed = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2,
                          width: width, height: height)
        return shrinkToFit(seed, bounds: bounds, image: image, radians: radians)
    }

    /// Reubica un rect al girar el bounding box 90° (clockwise = true) manteniendo el encuadre.
    static func rotated90(_ rect: CGRect, bounds: CGSize, clockwise: Bool) -> CGRect {
        if clockwise {
            return CGRect(x: bounds.height - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        } else {
            return CGRect(x: rect.minY, y: bounds.width - rect.maxX, width: rect.height, height: rect.width)
        }
    }
}

/// Zona agarrada durante un arrastre.
enum CropHandle {
    case topLeft, topRight, bottomLeft, bottomRight
    case top, bottom, left, right
    case move

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        default: return false
        }
    }

    var cursor: NSCursor {
        switch self {
        case .move: return .openHand
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        default: return .crosshair
        }
    }
}

// MARK: - Vista

struct CropEditorView: View {
    let url: URL
    let previewImage: NSImage
    let onCancel: () -> Void
    /// Se llama tras sobrescribir el original. Entrega la URL del backup para el undo.
    let onCommit: (URL) -> Void

    @State private var transform: CropTransform
    /// Rect de recorte en unidades de imagen (ancho de la imagen = 1), sobre el bounding box rotado.
    @State private var crop: CGRect
    @State private var aspect: CropAspect = .free
    @State private var dragHandle: CropHandle?
    @State private var dragStartCrop: CGRect = .zero
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var keyMonitor: Any?
    @State private var fullPixelWidth: CGFloat?

    private let barHeight: CGFloat = 96
    private let edgeInset: CGFloat = 32
    private let minCropSize: CGFloat = 0.03

    init(url: URL, previewImage: NSImage, flipH: Bool,
         onCancel: @escaping () -> Void, onCommit: @escaping (URL) -> Void) {
        self.url = url
        self.previewImage = previewImage
        self.onCancel = onCancel
        self.onCommit = onCommit
        _transform = State(initialValue: CropTransform(quarterTurns: 0, fineAngle: 0, flipH: flipH))
        let size = previewImage.size
        let unitHeight = size.width > 0 ? size.height / size.width : 1
        _crop = State(initialValue: CGRect(x: 0, y: 0, width: 1, height: unitHeight))
    }

    /// Tamaño de la imagen sin rotar, normalizado a ancho 1.
    private var unitSize: CGSize {
        let size = previewImage.size
        guard size.width > 0, size.height > 0 else { return CGSize(width: 1, height: 1) }
        return CGSize(width: 1, height: size.height / size.width)
    }

    private var imageAspect: CGFloat { unitSize.width / unitSize.height }
    private var boundsSize: CGSize { transform.rotatedBounds(of: unitSize) }

    /// Tamaño en píxeles reales del recorte resultante.
    private var outputPixelSize: CGSize {
        let base = fullPixelWidth ?? previewImage.size.width
        return CGSize(width: (crop.width * base).rounded(), height: (crop.height * base).rounded())
    }

    var body: some View {
        GeometryReader { geo in
            let layout = makeLayout(in: geo.size)

            ZStack {
                Color.black.ignoresSafeArea()

                Image(nsImage: previewImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: unitSize.width * layout.scale, height: unitSize.height * layout.scale)
                    .scaleEffect(x: transform.flipH ? -1 : 1, y: 1)
                    .rotationEffect(.degrees(transform.angle))
                    .position(x: layout.boundsRect.midX, y: layout.boundsRect.midY)

                dimmingOverlay(cropRect: layout.cropRect, canvas: geo.size)
                cropChrome(rect: layout.cropRect)

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(dragGesture(layout: layout))
                    .onContinuousHover { phase in
                        guard !isSaving else { return }
                        switch phase {
                        case .active(let point):
                            (handle(at: point, in: layout.cropRect)?.cursor ?? NSCursor.arrow).set()
                        case .ended:
                            NSCursor.arrow.set()
                        }
                    }

                VStack {
                    Spacer()
                    controlBar
                }

                if isSaving {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text("Guardando…").foregroundColor(.white)
                    }
                }
            }
        }
        .alert("No se pudo recortar", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            loadFullPixelWidth()
            installKeyMonitor()
        }
        .onDisappear {
            if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
            keyMonitor = nil
            NSCursor.arrow.set()
        }
    }

    // MARK: Layout

    private struct Layout {
        let scale: CGFloat
        let boundsRect: CGRect
        let cropRect: CGRect
    }

    private func makeLayout(in canvas: CGSize) -> Layout {
        let bounds = boundsSize
        let available = CGSize(width: max(1, canvas.width - edgeInset * 2),
                               height: max(1, canvas.height - barHeight - edgeInset * 2))
        let scale = min(available.width / bounds.width, available.height / bounds.height)
        let boundsRect = CGRect(
            x: (canvas.width - bounds.width * scale) / 2,
            y: (canvas.height - barHeight - bounds.height * scale) / 2,
            width: bounds.width * scale,
            height: bounds.height * scale)
        let cropRect = CGRect(x: boundsRect.minX + crop.minX * scale,
                              y: boundsRect.minY + crop.minY * scale,
                              width: crop.width * scale,
                              height: crop.height * scale)
        return Layout(scale: scale, boundsRect: boundsRect, cropRect: cropRect)
    }

    // MARK: Overlays

    private func dimmingOverlay(cropRect: CGRect, canvas: CGSize) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: canvas))
            path.addRect(cropRect)
        }
        .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private func cropChrome(rect: CGRect) -> some View {
        ZStack {
            // Guías de tercios
            Path { path in
                for i in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: rect.minY))
                    path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    let y = rect.minY + rect.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: rect.minX, y: y))
                    path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)

            Rectangle()
                .stroke(Color.white, lineWidth: 1)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            ForEach(Array(handlePoints(in: rect).enumerated()), id: \.offset) { _, point in
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .position(point)
            }
        }
        .allowsHitTesting(false)
    }

    private func handlePoints(in rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
         CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY),
         CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY)]
    }

    // MARK: Barra de controles

    private var controlBar: some View {
        HStack(spacing: 14) {
            Button { rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }
                .help("Rotar 90° a la izquierda (⌘←)")

            HStack(spacing: 8) {
                Slider(value: Binding(
                    get: { transform.fineAngle },
                    set: { setFineAngle($0) }
                ), in: -45...45)
                .frame(width: 220)
                Text(String(format: "%.1f°", transform.fineAngle))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 52, alignment: .leading)
            }

            Button { rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }
                .help("Rotar 90° a la derecha (⌘→)")

            Divider().frame(height: 22)

            Picker("", selection: Binding(
                get: { aspect },
                set: { applyAspectPreset($0) }
            )) {
                ForEach(CropAspect.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 340)
            .labelsHidden()

            Spacer()

            Text("\(Int(outputPixelSize.width)) × \(Int(outputPixelSize.height)) px")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))

            Button("Restablecer") { resetAll() }
            Button("Cancelar") { onCancel() }
            Button("Aplicar") { commit() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .frame(height: barHeight)
        .background(Color.black.opacity(0.85))
        .foregroundColor(.white)
        .disabled(isSaving)
    }

    // MARK: Interacción

    private func handle(at point: CGPoint, in rect: CGRect) -> CropHandle? {
        let corner: CGFloat = 22
        let edge: CGFloat = 14
        let nearLeft = abs(point.x - rect.minX) <= corner
        let nearRight = abs(point.x - rect.maxX) <= corner
        let nearTop = abs(point.y - rect.minY) <= corner
        let nearBottom = abs(point.y - rect.maxY) <= corner
        let insideY = point.y >= rect.minY - corner && point.y <= rect.maxY + corner
        let insideX = point.x >= rect.minX - corner && point.x <= rect.maxX + corner

        if insideX && insideY {
            if nearLeft && nearTop { return .topLeft }
            if nearRight && nearTop { return .topRight }
            if nearLeft && nearBottom { return .bottomLeft }
            if nearRight && nearBottom { return .bottomRight }
            if abs(point.y - rect.minY) <= edge { return .top }
            if abs(point.y - rect.maxY) <= edge { return .bottom }
            if abs(point.x - rect.minX) <= edge { return .left }
            if abs(point.x - rect.maxX) <= edge { return .right }
        }
        if rect.contains(point) { return .move }
        return nil
    }

    private func dragGesture(layout: Layout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragHandle == nil {
                    guard let hit = handle(at: value.startLocation, in: layout.cropRect) else { return }
                    dragHandle = hit
                    dragStartCrop = crop
                }
                guard let active = dragHandle, layout.scale > 0 else { return }
                let delta = CGSize(width: value.translation.width / layout.scale,
                                   height: value.translation.height / layout.scale)
                updateCrop(handle: active, from: dragStartCrop, delta: delta)
            }
            .onEnded { _ in
                dragHandle = nil
            }
    }

    private func updateCrop(handle: CropHandle, from start: CGRect, delta: CGSize) {
        let bounds = boundsSize
        let radians = transform.radians
        var candidate: CGRect

        if handle == .move {
            candidate = start.offsetBy(dx: delta.width, dy: delta.height)
        } else {
            var minX = start.minX, maxX = start.maxX
            var minY = start.minY, maxY = start.maxY
            switch handle {
            case .topLeft:     minX += delta.width; minY += delta.height
            case .topRight:    maxX += delta.width; minY += delta.height
            case .bottomLeft:  minX += delta.width; maxY += delta.height
            case .bottomRight: maxX += delta.width; maxY += delta.height
            case .top:         minY += delta.height
            case .bottom:      maxY += delta.height
            case .left:        minX += delta.width
            case .right:       maxX += delta.width
            case .move:        break
            }
            guard maxX - minX >= minCropSize, maxY - minY >= minCropSize else { return }
            candidate = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

            if let ratio = aspect.ratio(imageAspect: imageAspect) {
                candidate = enforceRatio(candidate, handle: handle, anchor: start, ratio: ratio)
            }
        }

        guard candidate.width >= minCropSize, candidate.height >= minCropSize else { return }
        guard CropGeometry.isContained(candidate, bounds: bounds, image: unitSize, radians: radians) else { return }
        crop = candidate
    }

    /// Reimpone la proporción manteniendo fijo el lado/esquina opuesto al que se arrastra.
    private func enforceRatio(_ rect: CGRect, handle: CropHandle, anchor: CGRect, ratio: CGFloat) -> CGRect {
        var width = rect.width
        var height = rect.height

        switch handle {
        case .top, .bottom:
            width = height * ratio
        case .left, .right:
            height = width / ratio
        default:
            // En esquinas manda el eje con mayor cambio relativo.
            if abs(rect.width - anchor.width) >= abs(rect.height - anchor.height) {
                height = width / ratio
            } else {
                width = height * ratio
            }
        }

        var x = rect.minX
        var y = rect.minY
        switch handle {
        case .topLeft:     x = rect.maxX - width; y = rect.maxY - height
        case .topRight:    x = rect.minX;         y = rect.maxY - height
        case .bottomLeft:  x = rect.maxX - width; y = rect.minY
        case .bottomRight: x = rect.minX;         y = rect.minY
        case .top:         x = rect.midX - width / 2; y = rect.maxY - height
        case .bottom:      x = rect.midX - width / 2; y = rect.minY
        case .left:        x = rect.maxX - width;     y = rect.midY - height / 2
        case .right:       x = rect.minX;             y = rect.midY - height / 2
        case .move:        break
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: Rotación / presets

    private func setFineAngle(_ value: Double) {
        // Snap suave alrededor de 0 para recuperar el ángulo exacto.
        let snapped = abs(value) < 0.15 ? 0 : value
        guard snapped != transform.fineAngle else { return }
        transform.fineAngle = snapped
        refitCrop()
    }

    private func rotate(clockwise: Bool) {
        let oldBounds = boundsSize
        transform.quarterTurns = ((transform.quarterTurns + (clockwise ? 1 : 3)) % 4 + 4) % 4
        crop = CropGeometry.rotated90(crop, bounds: oldBounds, clockwise: clockwise)
        refitCrop()
    }

    private func refitCrop() {
        let bounds = boundsSize
        crop = CropGeometry.shrinkToFit(crop, bounds: bounds, image: unitSize, radians: transform.radians)
    }

    private func applyAspectPreset(_ option: CropAspect) {
        aspect = option
        guard let ratio = option.ratio(imageAspect: imageAspect) else { return }
        let bounds = boundsSize
        var width = crop.width
        var height = width / ratio
        if height > crop.height {
            height = crop.height
            width = height * ratio
        }
        let seed = CGRect(x: crop.midX - width / 2, y: crop.midY - height / 2, width: width, height: height)
        crop = CropGeometry.shrinkToFit(seed, bounds: bounds, image: unitSize, radians: transform.radians)
    }

    private func resetAll() {
        transform.quarterTurns = 0
        transform.fineAngle = 0
        aspect = .free
        crop = CGRect(origin: .zero, size: unitSize)
    }

    // MARK: Teclado

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !isSaving else { return event }
            let flags = event.modifierFlags
            let command = flags.contains(.command)
            let shift = flags.contains(.shift)

            switch event.keyCode {
            case 53: // Esc
                onCancel(); return nil
            case 36, 76: // Return / Enter
                commit(); return nil
            case 123: // ←
                if command { rotate(clockwise: false) }
                else { setFineAngle(max(-45, transform.fineAngle - (shift ? 1.0 : 0.1))) }
                return nil
            case 124: // →
                if command { rotate(clockwise: true) }
                else { setFineAngle(min(45, transform.fineAngle + (shift ? 1.0 : 0.1))) }
                return nil
            default:
                break
            }

            guard !command else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r": resetAll(); return nil
            case "1": applyAspectPreset(.free); return nil
            case "2": applyAspectPreset(.original); return nil
            case "3": applyAspectPreset(.square); return nil
            case "4": applyAspectPreset(.fourThree); return nil
            case "5": applyAspectPreset(.sixteenNine); return nil
            case "6": applyAspectPreset(.threeTwo); return nil
            default: return event
            }
        }
    }

    // MARK: Datos / guardado

    private func loadFullPixelWidth() {
        let target = url
        DispatchQueue.global(qos: .userInitiated).async {
            let accessed = target.startAccessingSecurityScopedResource()
            defer { if accessed { target.stopAccessingSecurityScopedResource() } }
            guard let source = CGImageSourceCreateWithURL(target as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return }
            let width = (props[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
            let height = (props[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0
            let orientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
            // Con orientaciones 5...8 el ancho visible es la altura almacenada.
            let visibleWidth = orientation >= 5 ? height : width
            guard visibleWidth > 0 else { return }
            DispatchQueue.main.async { fullPixelWidth = visibleWidth }
        }
    }

    private func commit() {
        guard !isSaving else { return }
        isSaving = true
        let target = url
        let currentTransform = transform
        let currentCrop = crop
        let unit = unitSize

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let backup = try CropRenderer.applyCrop(to: target,
                                                        transform: currentTransform,
                                                        crop: currentCrop,
                                                        unitSize: unit)
                DispatchQueue.main.async {
                    isSaving = false
                    onCommit(backup)
                }
            } catch {
                DispatchQueue.main.async {
                    isSaving = false
                    errorMessage = error.localizedDescription
                    NSSound.beep()
                }
            }
        }
    }
}
