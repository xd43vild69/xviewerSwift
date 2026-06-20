🔴 


    

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


