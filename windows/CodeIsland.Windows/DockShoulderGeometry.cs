using System.Windows;
using System.Windows.Media;
using WpfPoint = System.Windows.Point;
using WpfSize = System.Windows.Size;

namespace CodeIsland.Windows;

public static class DockShoulderGeometry
{
    public static (Geometry First, Geometry Second) Create(WpfSize size, DockEdges edges, double depth = 38, double curve = 28)
    {
        if (edges.HasFlag(DockEdges.Top))
            return (VerticalShoulder(depth, size.Height, curve, left: true, top: true, size.Width),
                VerticalShoulder(depth, size.Height, curve, left: false, top: true, size.Width));
        if (edges.HasFlag(DockEdges.Bottom))
            return (VerticalShoulder(depth, size.Height, curve, left: true, top: false, size.Width),
                VerticalShoulder(depth, size.Height, curve, left: false, top: false, size.Width));
        if (edges.HasFlag(DockEdges.Left))
            return (HorizontalShoulder(size.Width, depth, curve, top: true, left: true, size.Height),
                HorizontalShoulder(size.Width, depth, curve, top: false, left: true, size.Height));
        if (edges.HasFlag(DockEdges.Right))
            return (HorizontalShoulder(size.Width, depth, curve, top: true, left: false, size.Height),
                HorizontalShoulder(size.Width, depth, curve, top: false, left: false, size.Height));
        return (Geometry.Empty, Geometry.Empty);
    }

    private static Geometry VerticalShoulder(double width, double height, double curve, bool left, bool top, double panelWidth)
    {
        var x0 = left ? 0 : panelWidth - width;
        var inner = left ? x0 + width : x0;
        var outer = left ? x0 : x0 + width;
        var edgeY = top ? 0 : height;
        var taperY = top ? curve : height - curve;
        var geometry = new StreamGeometry();
        using var context = geometry.Open();
        context.BeginFigure(new WpfPoint(inner, edgeY), true, true);
        context.LineTo(new WpfPoint(outer, edgeY), true, false);
        context.BezierTo(
            new WpfPoint(outer + (inner - outer) * .35, edgeY),
            new WpfPoint(inner, taperY + (edgeY - taperY) * .35),
            new WpfPoint(inner, taperY), true, false);
        geometry.Freeze();
        return geometry;
    }

    private static Geometry HorizontalShoulder(double width, double height, double curve, bool top, bool left, double panelHeight)
    {
        var y0 = top ? 0 : panelHeight - height;
        var inner = top ? y0 + height : y0;
        var outer = top ? y0 : y0 + height;
        var edgeX = left ? 0 : width;
        var taperX = left ? curve : width - curve;
        var geometry = new StreamGeometry();
        using var context = geometry.Open();
        context.BeginFigure(new WpfPoint(edgeX, inner), true, true);
        context.LineTo(new WpfPoint(edgeX, outer), true, false);
        context.BezierTo(
            new WpfPoint(edgeX, outer + (inner - outer) * .35),
            new WpfPoint(taperX + (edgeX - taperX) * .35, inner),
            new WpfPoint(taperX, inner), true, false);
        geometry.Freeze();
        return geometry;
    }
}
