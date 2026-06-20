🔴 

Crear en el context menu una opcion que permite particionar una gran carpeta en bloques de carpetas mas manegables para RED SMB, 
al dar click en "partitioning" en el context menu se dividen las imagenes existentes de la carpeta actual en bloques de imagenes en nuevas carpetas en bloques de 100 imagenes por capeta.

cada carpeta debe tener el mismo nombre de la carpeta padre mas un consecutivo

 

cuando presione una tecla sola como s o a del teclado debe posicionarse en la carpeta que contenga esta letra inicialmente, del panel activo

---


10. **Etiquetas o Clasificación:** Poder ponerles estrellas (del 1 al 5) o etiquetas de colores tipo Finder a las imágenes para organizarlas mejor.


4. **Deshacer (Undo):** Implementar el clásico `Cmd + Z`. Si borraste una imagen o la moviste por accidente, poder revertir esa acción de forma inmediata.

7. **Refresco Automático:** Si otra aplicación o el Finder crea o elimina un archivo en la carpeta que estás viendo, nuestra app debería detectarlo y actualizarse automáticamente sin tener que recargar la carpeta de forma manual.



Listed directory xviewerSwift
Searched for "Grid"

Para poder soportar diferentes modos de visualización (como cuadrícula y lista) en lugar de solo la cuadrícula actual, se necesitarían realizar cambios en varias áreas clave de la aplicación. Según la estructura actual del proyecto (`PaneBrowserView.swift`, `ContentView.swift`, y `BrowserSession.swift`), esto es lo que se requiere:

### 1. Gestión de Estado (State Management)
*   **Definir los modos de vista:** Se debe crear una enumeración (por ejemplo, `enum ViewMode { case grid, list }`) para representar los modos disponibles.
*   **Almacenar el estado:** Agregar una variable de estado en el modelo de datos principal (probablemente en `BrowserSession` o en los ajustes globales del usuario) para guardar el modo seleccionado actualmente (`@Published var viewMode: ViewMode = .grid`).

### 2. Interfaz de Usuario (UI Toggle)
*   **Controlador de cambio:** Agregar un botón o un control segmentado (`Picker` o botones de íconos como cuadrícula/lista) en la barra de herramientas (Toolbar) o en la barra de navegación para que el usuario pueda alternar entre los diferentes modos.

### 3. Lógica de Renderizado en `PaneBrowserView`
*   **Estructuras condicionales:** En `PaneBrowserView.swift`, donde actualmente está codificado directamente el `LazyVGrid`, se necesitaría un bloque `if` o `switch` que dependa de la variable `viewMode`.
    *   Si es cuadrícula, renderiza el `LazyVGrid` actual.
    *   Si es lista, renderiza un `LazyVStack` o un componente `List`.

### 4. Nuevas Vistas para los Elementos (Cells)
*   **Diseño de la celda de lista:** Actualmente tienes un `GridItemCell` (en `ContentView.swift`). Se necesitaría diseñar un nuevo componente (por ejemplo, `ListItemCell`) optimizado para mostrarse en lista. Esta celda usualmente mostraría una miniatura más pequeña a la izquierda y el nombre del archivo, fecha, tamaño y otros detalles a la derecha.

### 5. Navegación por Teclado (`BrowserSession`)
*   **Lógica de flechas:** Actualmente en `BrowserSession.swift` existen métodos como `navigateGridRow` y `navigateGrid` que calculan el siguiente elemento usando columnas y filas.
*   Se requeriría adaptar esta lógica. En el modo lista, presionar la flecha hacia arriba o hacia abajo simplemente cambiaría el índice en `-1` o `+1`, y las flechas laterales podrían deshabilitarse o usarse para expandir/colapsar carpetas si fuera una vista de árbol.

### 6. Cálculos de Geometría y Paginación (`ContentView`)
*   **Cálculo de elementos visibles:** En `ContentView.swift` se usan variables como `rowStride`, `cellW`, `minRow`, y `maxRow` basadas en `GridLayout`. 
*   Se necesitaría una lógica paralela (por ejemplo, `ListLayout`) para calcular qué elementos están visibles en pantalla cuando se usa el modo lista (ya que el alto de la celda cambia y solo hay 1 columna), lo cual es importante para la carga diferida (lazy loading) o el cálculo de selecciones y desplazamientos automáticos (scroll offsets).


---


# TODO Avanzado

I will inspect the workspace directory to understand the current structure and implementation status of the `xviewerSwift` project.

Listed directory xviewerSwift

I will list the contents of the main source folder to see the SwiftUI files and structural components.

Listed directory xviewerSwift

I will list the source files of the application to see the actual components of the app.

Listed directory xviewerSwift

I will view the `README.md` file to see the current feature list and description of the app.

Viewed README.md:1-58

I will view a section of `BrowserSession.swift` to understand how the browser session, file loading, and indexing logic are currently structured.

Viewed BrowserSession.swift:1-150

I will view `PropertiesSubsystem.swift` to understand how the application handles image and file properties / metadata.

Viewed PropertiesSubsystem.swift:1-150

I will list files inside the UI and Utilities folders to see how images are rendered and what helper modules currently exist.

Listed directory UI

I will list files inside the Utilities directory.

Listed directory Utilities

I will list the components folder to see if there are any specific image cells, viewers, or custom controls.

Listed directory Components

I will list the contents of the Cards directory.

Listed directory Cards

I will list the contents of the Layouts directory.

Listed directory Layouts

I will search for `RAW` and `Lightroom` references in the project to verify how RAW files and Lightroom integrations are handled under the hood.

Searched for "lightroom"

Basándome en un análisis de la arquitectura actual de **xviewerSwift** y en los estándares exigidos por profesionales de la fotografía y la gestión de archivos digitales (quienes utilizan herramientas como Adobe Bridge, Photo Mechanic o Path Finder), aquí tienes las 7 características ausentes más críticas para elevar la aplicación a un nivel profesional, ordenadas de **más relevante a menos relevante**:

---

### 1. Soporte integral de metadatos estándar (EXIF / IPTC / XMP) y sistema de clasificación (Rating & Tagging)
* **Por qué falta:** Actualmente, el panel de propiedades está limitado a extraer metadatos muy específicos (como flujos de trabajo de ComfyUI para PNGs).
* **Análisis profesional:** Un flujo de trabajo profesional requiere lectura completa de datos EXIF (apertura, velocidad de obturación, ISO, distancia focal, lente, cámara, coordenadas GPS) y datos IPTC/XMP (derechos de autor, creador). Además, es fundamental contar con un sistema ágil para **clasificar imágenes con estrellas (1-5)** y **etiquetas de colores**. Sin esta capacidad de criba rápida (culling), un fotógrafo no puede utilizar la app para seleccionar su material de trabajo.

### 2. Motor de caché persistente y pre-renderizado en segundo plano (Persistent Caching & Prefetching)
* **Por qué falta:** La generación de miniaturas se realiza sobre la marcha delegando en QuickLook, y no existe un almacenamiento indexado permanente.
* **Análisis profesional:** Al abrir directorios profesionales con miles de imágenes de alta resolución o archivos RAW pesados, la falta de una base de datos local (como SQLite o Core Data) que actúe como caché de miniaturas provoca cuellos de botella constantes en el procesador y el almacenamiento. La app requiere indexar el contenido en segundo plano y pre-cargar en memoria (prefetching) las imágenes adyacentes a la actual para garantizar que el paso entre imágenes en pantalla completa sea instantáneo y libre de latencia.

### 3. Gestión y precisión de color (ColorSync & Perfiles ICC)
* **Por qué falta:** La aplicación renderiza imágenes a través del flujo estándar de SwiftUI sin realizar mapeos o correcciones explícitas de color.
* **Análisis profesional:** Los fotógrafos y diseñadores trabajan en múltiples espacios de color (sRGB, Adobe RGB, DCI-P3, ProPhoto RGB). Si la aplicación no interpreta correctamente los perfiles ICC incrustados en cada archivo y no los mapea al perfil de calibración del monitor del Mac mediante **ColorSync / Core Graphics**, las imágenes se mostrarán con colores apagados, sobresaturados o inexactos. Para que sea una herramienta profesional de inspección visual, la fidelidad de color es innegociable.

### 4. Sistema multinivel de Deshacer/Rehacer (Undo/Redo) e integración con la Papelera del sistema
* **Por qué falta:** Las operaciones sobre archivos (renombrado por lotes, copias, movimientos y borrados) se ejecutan directamente sobre el sistema de archivos a través de `FileManager` sin posibilidad de revertirse de forma nativa.
* **Análisis profesional:** El error humano es común al gestionar cientos de archivos. Si un usuario ejecuta un renombrado masivo erróneo o arrastra una carpeta a otra por accidente, la app debe permitir deshacer la acción (`Cmd + Z`). Asimismo, la eliminación de archivos debe enviar los elementos a la Papelera de macOS (`NSWorkspace.recycle`) en lugar de destruirlos de forma inmediata e irreversible, ofreciendo una red de seguridad esencial en entornos de producción.

### 5. Búsqueda Avanzada, Filtrado Dinámico y Carpetas Inteligentes (Smart Folders)
* **Por qué falta:** Las opciones actuales se limitan a ordenamientos básicos por nombre, fecha y tamaño dentro de la carpeta actual.
* **Análisis profesional:** Los usuarios profesionales necesitan buscar y filtrar colecciones masivas de archivos rápidamente. Se echa en falta un motor de búsqueda avanzada (con soporte para caracteres comodín o regex) y filtros dinámicos que permitan cruzar variables (por ejemplo: "mostrar solo archivos RAW, capturados a ISO 1600, con lente de 50mm y que tengan 4 o más estrellas"). La posibilidad de guardar estas búsquedas como "Carpetas Inteligentes" automatizaría drásticamente el acceso a proyectos activos.

### 6. Modo de comparación visual (Compare & Survey Mode) y decodificador RAW nativo
* **Por qué falta:** La visualización de pantalla completa es estrictamente de una en una y depende del visor por defecto de la imagen seleccionada.
* **Análisis profesional:** Para elegir la mejor toma de una ráfaga (evaluando cuál tiene mejor enfoque o menor ruido), los profesionales necesitan un modo de comparación lado a lado (2, 3 o 4 imágenes simultáneas) con controles de zoom y paneo sincronizados. Adicionalmente, se requiere soporte nativo de decodificación RAW (mediante Apple Core Image RAW filters) para ajustar temporalmente la exposición o el balance de blancos al inspeccionar, en lugar de depender únicamente de las miniaturas JPEG incrustadas en el RAW.

### 7. Herramientas de procesamiento y exportación por lotes (Batch Export & Conversion)
* **Por qué falta:** La app redirige el procesamiento pesado a aplicaciones externas (Lightroom o Krita) pero no cuenta con funciones nativas de conversión.
* **Análisis profesional:** Antes de compartir fotos con clientes o subirlas a la web, es habitual necesitar exportaciones rápidas. Una utilidad profesional integrada de procesamiento por lotes permitiría seleccionar un conjunto de imágenes y aplicarles presets de exportación: redimensionamiento de escala, conversión de formato (por ejemplo, de TIFF o RAW a WebP/JPEG), eliminación de metadatos sensibles (GPS) y aplicación de marcas de agua o firmas digitales de forma masiva.




------



# Performance


I will search for `loadFolder` or thumbnail generation code in `BrowserSession.swift` to see how the files are read, parsed, and cached.

Searched for "func loadFolder"

I will inspect the folder loading implementation in `BrowserSession.swift` around line 820.

Viewed BrowserSession.swift:820-930

I will search for `ThumbnailLoader` class definition to see how thumbnails are generated and cached.

Searched for "class ThumbnailLoader"

I will view the `ThumbnailLoader` class definition in `ContentView.swift` around line 28.

Viewed ContentView.swift:20-160

I will view more of `ContentView.swift` to inspect how thumbnails are loaded for network/non-local files.

Viewed ContentView.swift:160-200

Aquí tienes el análisis detallado de los problemas de rendimiento más graves al previsualizar imágenes (tanto en local como en red) y otros cuellos de botella que requieren una refactorización en **xviewerSwift**:

---

### I. Problemas de rendimiento graves en previsualización (Local y Red)

#### 1. Previsualización y Miniaturas en Red (SMB / NFS / Unidades Externas)
* **Descarga/Lectura completa como plan de contingencia (Fallback over Network):** Si la generación de QuickLook (`QLThumbnailGenerator`) falla o no está disponible para un archivo en red, el código recurre a `CGImageSourceCreateThumbnailAtIndex`. Esto descarga y procesa el archivo binario completo (que pueden ser decenas de megabytes si es un archivo RAW o TIFF) a través de la red solo para generar una miniatura de 160px, congestionando drásticamente el ancho de banda y congelando la interfaz.
* **Viajes de ida y vuelta síncronos en la enumeración (Network Round-trips):** Durante `loadFolder`, el enumerador realiza consultas individuales de propiedades de archivo (`fileURL.resourceValues(forKeys:)`) secuencialmente para cada elemento. En red, cada consulta añade latencia de comunicación (round-trip delay), lo que hace que listar directorios remotos con cientos de imágenes sea extremadamente lento en comparación con una lectura por lotes (bulk read).

#### 2. Previsualización y Miniaturas en Local
* **Saturación del subsistema de E/S (Disk I/O Choke):** Aunque `ThumbnailLoader` limita las tareas locales concurrentes a 8, abrir una carpeta con cientos de archivos grandes (ej. RAW de 50MB o más) provoca que se encolen decenas de tareas que leen el disco simultáneamente. Esto compite por el ancho de banda del SSD y ralentiza tanto el renderizado de la cuadrícula como la navegación general.
* **Falta de descompresión progresiva en Pantalla Completa:** Al abrir una imagen en pantalla completa, se carga el recurso completo directamente. Para pantallas Retina de alta densidad y archivos masivos, esto puede causar micro-tirones (jank) de interfaz si la imagen no se decodifica en un hilo de fondo optimizado con reducción de escala (downsampling) proporcional a la resolución de la pantalla.

---

### II. Otros problemas de rendimiento que requieren refactorización

#### 1. Actualización destructiva de la Grid de SwiftUI (`folderContents` Updates)
* **Reemplazo total del estado:** En `loadFolder`, la lista completa se ordena en segundo plano y luego se asigna directamente a `self.folderContents` en el hilo principal. Esto destruye e inserta la lista entera en SwiftUI. Para carpetas grandes (miles de elementos), este reemplazo masivo obliga a SwiftUI a recalcular el layout de toda la cuadrícula (`LazyVGrid`), causando caídas graves de fotogramas (dropped frames).
* **Refactorización recomendada:** Implementar actualizaciones diferenciales (diffing) o paginación/carga diferida de la lista para actualizar solo los elementos visibles, utilizando identificadores estables y persistentes.

#### 2. Lectura ineficiente de metadatos (PNG Text Chunks)
* **Escaneo lineal del archivo:** En `PropertiesSubsystem.swift`, para buscar los metadatos de ComfyUI (`prompt` y `workflow`), se abre un `FileHandle` y se lee secuencialmente el archivo PNG. Si la imagen es muy grande, esto consume recursos de lectura innecesarios.
* **Refactorización recomendada:** Modificar el lector binario para analizar únicamente las cabeceras del archivo PNG y los primeros bloques de metadatos, deteniendo la lectura tan pronto como empiece el bloque de datos de imagen (`IDAT`), o utilizar mapas de memoria (`Data(contentsOf:options: .mappedIfSafe)`).

#### 3. Recarga masiva ante cambios de archivos (Directory Observers)
* **Falta de reactividad granular:** Al realizar operaciones de archivo (mover, copiar o borrar), la aplicación invoca un `loadFolder` completo para refrescar la interfaz (como se observa tras resolver conflictos o renombrar). Esto obliga a re-enumerar todo el directorio y regenerar el estado desde cero.
* **Refactorización recomendada:** Utilizar APIs nativas como `FSEvents` o `DispatchSourceFileSystem` para escuchar cambios específicos y actualizar la colección `folderContents` de manera incremental (añadiendo, eliminando o modificando únicamente los items afectados) en lugar de recargar la carpeta entera.

#### 4. Cancelación ineficaz de tareas de miniaturas (Orphaned Tasks)
* **Procesamiento de tareas huérfanas:** Cuando el usuario navega rápidamente de una carpeta a otra, las tareas de generación de miniaturas que ya han pasado el estado de espera (`wait()`) continúan ejecutándose en segundo plano hasta completarse, a pesar de que el usuario ya no está visualizando esa carpeta. `CGImageSourceCreateThumbnailAtIndex` es una llamada síncrona de C que no responde a la cancelación cooperativa de Swift una vez iniciada.
* **Refactorización recomendada:** Implementar un sistema de cancelación activa que invalide o descarte explícitamente los hilos de decodificación y limpie la cola de solicitudes del cargador de miniaturas inmediatamente al cambiar de directorio.
