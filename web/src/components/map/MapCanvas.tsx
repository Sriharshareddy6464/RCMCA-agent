import { forwardRef } from 'react'
import type { MapCanvasHandle, MapCanvasProps } from '../../types/contracts'

const MapCanvas = forwardRef<MapCanvasHandle, MapCanvasProps>(function MapCanvas(_props, _ref) {
  return <div data-skeleton="MapCanvas" />
})

export default MapCanvas
