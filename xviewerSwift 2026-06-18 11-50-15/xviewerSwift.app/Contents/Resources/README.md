Con gusto. El código fuente de tu visor de imágenes (XViewerSwift) está construido usando **SwiftUI** para la interfaz gráfica y las **APIs nativas de macOS** para el manejo de archivos y ventanas.

Para que sea fácil de entender, podemos dividir la arquitectura de la aplicación en **5 componentes principales**:

### 1. El motor principal (`ContentView`)
Es el corazón de la aplicación. Aquí se define la interfaz principal dividida en dos paneles:
- **Panel Izquierdo:** Muestra la información básica de la carpeta actual.
- **Panel Derecho:** Contiene el `ScrollView` y el `LazyVGrid` que dibujan la cuadrícula de imágenes.
También es el lugar donde se centralizan todos los atajos de teclado (flechas, espacio, borrar, copiar) y donde se guardan los "estados" (State) más importantes de la app, como la lista de imágenes cargadas (`folderContents`) y cuáles de ellas están seleccionadas (`selectedItemURLs`).

### 2. Carga eficiente de imágenes (`ThumbnailLoader`)
Dado que las carpetas pueden tener miles de imágenes o estar en discos de red (SMB), cargar las imágenes de forma normal congelaría la aplicación.
- Para evitarlo, el código utiliza un sistema de concurrencia moderno de Swift (`Task.detached` y `CheckedContinuation`).
- Funciona como una "fábrica" con trabajadores en segundo plano que van creando miniaturas de baja resolución (`CGImageSourceCreateThumbnailAtIndex`) sin interrumpir la fluidez de la cuadrícula.

### 3. Selección Múltiple y Geometría (`GridItemCell` y `FramePreferenceKey`)
SwiftUI en Mac no tiene una "caja de selección" (Lazo) nativa. Para lograr el *Drag-to-Select*, usamos matemáticas y geometría de coordenadas:
- Cada `GridItemCell` (que representa una sola imagen) usa un `GeometryReader` para medir exactamente en qué coordenadas de la pantalla (X, Y) está posicionado.
- A través de un `PreferenceKey`, las celdas "le gritan" sus coordenadas al `ContentView`.
- Cuando haces clic y arrastras, el programa dibuja un rectángulo azul y simplemente calcula de forma matemática qué coordenadas de imágenes chocan o se intersectan con tu rectángulo, marcándolas como seleccionadas.

### 4. Modo Pantalla Completa Inmersivo (`ImmersiveWindowController`)
Normalmente, SwiftUI abre ventanas nuevas con marcos y botones (cerrar, minimizar). Como querías un modo "Kiosko", creamos un controlador nativo usando `NSWindow`:
- Este controlador crea una ventana que flota por encima de todo (`.mainMenu` level), le quita los bordes, el título y el fondo.
- En su interior inyecta la vista `FullScreenImageView`, la cual se encarga de manejar los gestos complejos (zoom con trackpad, arrastre) y aplicar modificadores visuales como la inversión de color (`.colorInvert()`).

### 5. Permisos de macOS (Sandbox y Bookmarks)
macOS es muy estricto con la seguridad; una app no puede leer archivos de tu disco sin tu permiso explícito.
- Usamos el `.fileImporter` para que le des permiso a la app de leer una carpeta.
- Una vez dado el permiso, la app crea un **Security-Scoped Bookmark** y lo guarda en las preferencias (`UserDefaults`).
- Gracias a este "marcador seguro", la próxima vez que abres la app, esta le presenta el ticket al sistema operativo y macOS le vuelve a dar acceso a la carpeta sin tener que preguntarte de nuevo. Por eso también es necesario llamar a `startAccessingSecurityScopedResource()` cuando le pasamos imágenes a otras apps, como Krita.



---

Distribuir

Header change to anymac

Menu - Product - Archive


