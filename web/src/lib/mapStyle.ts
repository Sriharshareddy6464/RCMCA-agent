/** Flutter uses the OpenFreeMap Liberty style: mobile/lib/main.dart:27. */
export const MAP_STYLE_URL = 'https://tiles.openfreemap.org/styles/liberty'

/** Flutter camera center: mobile/lib/main.dart:26. */
export const DEFAULT_MAP_CENTER: [longitude: number, latitude: number] = [78.4867, 17.385]

/** Flutter camera zoom: mobile/lib/main.dart:2063-2065. */
export const DEFAULT_MAP_ZOOM = 12.3

export const DEFAULT_MAP_VIEW = {
  style: MAP_STYLE_URL,
  center: DEFAULT_MAP_CENTER,
  zoom: DEFAULT_MAP_ZOOM,
} as const
