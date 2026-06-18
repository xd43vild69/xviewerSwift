- 🔴 en status bar necesito mostrar ruta completa de archivo y su nombre
    El nombre debe permitirse ser copiado

- 🟡 Icono de la aplicacion

- 🟡 terminal integrated into the app, this is the most avance and sync feature

- 🟡 .ContextMenu() 
    click derecho debe mostrar opciones avanzadas como: ordenar - pegar - etc 
    piensa en 3ds max


---


Priorities

### 🔴 Alta Prioridad (Características Fundamentales)
Estas son funciones básicas que los usuarios esperan de forma casi obligatoria en cualquier administrador de archivos:

1. **Renombrado de Archivos y Carpetas:** Actualmente podemos mover, eliminar y copiar, pero no podemos cambiarle el nombre a un archivo existente. Poder presionar `Enter` sobre un archivo o hacer doble clic lento para editar su nombre es fundamental.
2. **Navegación entre Carpetas (Adelante / Atrás):** Si haces doble clic en una subcarpeta, deberías entrar en ella. Además, necesitamos un botón o atajo (`Cmd + Flecha Arriba`) para regresar al directorio padre o navegar por el historial.
3. **Soporte de Arrastrar y Soltar (Drag & Drop):** Poder seleccionar archivos en nuestra app y arrastrarlos hacia el Finder o hacia Photoshop/Krita, y viceversa (soltar archivos del escritorio hacia nuestra app).

### 🟡 Media Prioridad (Productividad y Organización)
Estas funciones mejoran drásticamente el flujo de trabajo y la velocidad:

4. **Deshacer (Undo):** Implementar el clásico `Cmd + Z`. Si borraste una imagen o la moviste por accidente, poder revertir esa acción de forma inmediata.
5. **Barra de Búsqueda y Filtros:** Un pequeño cuadro de texto para filtrar rápidamente los archivos de la carpeta actual por su nombre (ej. buscar "logo") o por extensión (ej. "*.png").
6. **Barra Lateral de Accesos Directos:** Actualmente nuestro panel izquierdo solo muestra el nombre de la carpeta. Sería ideal poder anclar ahí tus carpetas favoritas (Descargas, Escritorio, Proyectos) para saltar entre ellas rápidamente.
7. **Refresco Automático:** Si otra aplicación o el Finder crea o elimina un archivo en la carpeta que estás viendo, nuestra app debería detectarlo y actualizarse automáticamente sin tener que recargar la carpeta de forma manual.

### 🟢 Baja Prioridad (Avanzadas y para Usuarios Pro)
Funciones de "nicho", muy potentes, pero que dependen del tipo de usuario al que va dirigida la app:

8. **Panel de Información y EXIF:** Al presionar `Cmd + I` (o tener un panel lateral derecho), ver detalles avanzados de la fotografía: con qué cámara se tomó, el ISO, la apertura, dimensiones exactas y ubicación en el mapa.
9. **Acciones en Lote (Bulk Actions):** Seleccionar 50 imágenes y poder cambiarles el tamaño a todas al mismo tiempo, convertirlas a `.jpg` o renombrarlas masivamente (ej. "Viaje_01", "Viaje_02"...).
10. **Etiquetas o Clasificación:** Poder ponerles estrellas (del 1 al 5) o etiquetas de colores tipo Finder a las imágenes para organizarlas mejor.

