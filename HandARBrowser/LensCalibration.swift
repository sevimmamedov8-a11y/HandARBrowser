import UIKit

/// Alignment pattern in the same output geometry as the monoscopic compositor.
/// The pattern is static relative to the headset; both eyes see the same grid.
final class LensCalibrationView: UIView {
    var onChange: ((VRProfile) -> Void)?
    var onFinish: (() -> Void)?
    var onInteraction: (() -> Void)?
    private var profile: VRProfile
    private var parameter = 0
    private var gate = ReleaseClickGate<Int>()
    private var buttons: [UIButton] = []
    private var labels: [UILabel] = []
    private var progress: [UIProgressView] = []
    private var cursors = [UIView(), UIView()]
    private let names = ["Расстояние линз", "Телефон: горизонталь", "Телефон: высота", "Совмещение по вертикали", "Глаз → экран", "Кривизна k1", "Кривизна k2"]

    init(frame: CGRect, profile: VRProfile) {
        self.profile=profile
        super.init(frame:frame)
        backgroundColor=UIColor(white:0.045,alpha:1)
        isOpaque=true
        for eye in 0..<2 {
            let label=UILabel()
            label.textColor = .white
            label.font = .systemFont(ofSize:12,weight:.medium)
            label.numberOfLines=3
            label.textAlignment = .center
            addSubview(label);labels.append(label)
            for (action,title) in ["‹", "−", "+", "›", "Готово"].enumerated() {
                let button=UIButton(type:.system)
                var configuration=UIButton.Configuration.filled()
                configuration.title=title
                configuration.baseForegroundColor = .white
                configuration.baseBackgroundColor=UIColor(white:0.18,alpha:1)
                configuration.cornerStyle = .capsule
                button.configuration=configuration
                button.accessibilityLabel=["Предыдущая настройка","Уменьшить","Увеличить","Следующая настройка","Сохранить и закрыть"][action]
                button.addAction(UIAction { [weak self] _ in self?.perform(action) },for:.touchUpInside)
                addSubview(button);buttons.append(button)
            }
            let bar=UIProgressView(progressViewStyle:.bar)
            bar.progressTintColor = .cyan
            bar.trackTintColor=UIColor(white:0.2,alpha:1)
            addSubview(bar);progress.append(bar)
            let cursor=cursors[eye]
            cursor.bounds=CGRect(x:0,y:0,width:9,height:9)
            cursor.layer.cornerRadius=4.5
            cursor.backgroundColor = .white
            cursor.isUserInteractionEnabled=false
            cursor.isHidden=true
            addSubview(cursor)
        }
        updateLabels()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let half=bounds.width*0.5
        for eye in 0..<2 {
            let x=CGFloat(eye)*half
            labels[eye].frame=CGRect(x:x+10,y:bounds.height-126,width:half-20,height:64)
            let widths:[CGFloat]=[38,48,48,38,86]
            let total=widths.reduce(0,+)+24
            var left=x+(half-total)*0.5
            for action in 0..<5 {
                buttons[eye*5+action].frame=CGRect(x:left,y:bounds.height-56,width:widths[action],height:40)
                left+=widths[action]+6
            }
            progress[eye].frame=CGRect(x:x+24,y:bounds.height-8,width:half-48,height:3)
        }
        setNeedsDisplay()
    }

    private func value() -> Float {
        switch parameter {
        case 0:return profile.lensSeparationMM
        case 1:return profile.screenHorizontalOffsetMM ?? 0
        case 2:return profile.lensVerticalOffsetMM
        case 3:return profile.rightEyeVerticalOffsetMM ?? 0
        case 4:return profile.eyeToScreenMM
        case 5:return profile.k1
        default:return profile.k2
        }
    }

    private func updateLabels() {
        let number=String(format:parameter>=5 ? "%.3f" : "%.2f мм",value())
        let hint=parameter>=5 ? "Линии сетки должны выглядеть прямыми." : "Совмести два креста и круга в один."
        for label in labels { label.text="\(parameter+1)/7 · \(names[parameter]): \(number)\n\(hint)\n‹ › — настройка, − + — подгонка; затем «Готово»." }
    }

    private func perform(_ action: Int) {
        onInteraction?()
        if action==4 { profile.save();onFinish?();return }
        if action==0 { parameter=(parameter+6)%7 }
        else if action==3 { parameter=(parameter+1)%7 }
        else {
            let step:[Float]=[0.25,0.1,0.1,0.05,0.5,0.005,0.005]
            let lower:[Float]=[52,-8,-8,-4,30,0,-0.2]
            let upper:[Float]=[76,8,8,4,70,0.8,0.6]
            let next=min(upper[parameter],max(lower[parameter],value()+(action==1 ? -step[parameter]:step[parameter])))
            switch parameter {
            case 0:profile.lensSeparationMM=next
            case 1:profile.screenHorizontalOffsetMM=next
            case 2:profile.lensVerticalOffsetMM=next
            case 3:profile.rightEyeVerticalOffsetMM=next
            case 4:profile.eyeToScreenMM=next
            case 5:profile.k1=next
            default:profile.k2=next
            }
            profile.save();onChange?(profile)
        }
        updateLabels();setNeedsDisplay()
    }

    func cancelInteraction() {
        gate.cancel()
        for cursor in cursors {cursor.isHidden=true}
        for bar in progress {bar.progress=0}
    }

    func updatePointer(_ point: CGPoint?, down: Bool, allowBegin: Bool = true, dwell: Bool, time: Double) {
        guard let point else {cancelInteraction();return}
        let half=bounds.width*0.5
        guard half>0 else {cancelInteraction();return}
        let local=CGPoint(x:point.x.truncatingRemainder(dividingBy:half),y:point.y)
        for eye in 0..<2 {cursors[eye].center=CGPoint(x:local.x+CGFloat(eye)*half,y:local.y);cursors[eye].isHidden=false}
        let selected=buttons.firstIndex{!$0.isHidden && $0.frame.contains(local)}
        let committed=gate.update(target:selected,down:down,allowBegin:allowBegin,dwell:dwell,at:time)
        for bar in progress {bar.progress=Float(gate.dwellProgress)}
        for (index,button) in buttons.enumerated() {button.isHighlighted=selected.map{$0%5==index%5} ?? false}
        if let committed {buttons[committed].sendActions(for:.touchUpInside)}
    }

    override func draw(_ rect: CGRect) {
        guard let context=UIGraphicsGetCurrentContext() else {return}
        let half=bounds.width*0.5,aspect=Double(half/max(bounds.height,1))
        for eye in 0..<2 {
            context.saveGState()
            context.clip(to:CGRect(x:CGFloat(eye)*half,y:0,width:half,height:bounds.height))
            let c=VRLensMath.lensCenterUV(eye:eye,profile:profile)
            func point(_ uv: SIMD2<Double>) -> CGPoint? {
                let source=SIMD2<Double>(0.5,0.5)+(uv-SIMD2(0.5,0.5))*Double(profile.eyeToScreenMM/42)
                guard let p=MonoViewGeometry.displayUV(source:source,center:SIMD2(Double(c.x),Double(c.y)),aspect:aspect,k1:Double(profile.k1),k2:Double(profile.k2)) else {return nil}
                return CGPoint(x:CGFloat(eye)*half+CGFloat(p.x)*half,y:CGFloat(p.y)*bounds.height)
            }
            func stroke(_ points: [SIMD2<Double>],color:UIColor,width:CGFloat) {
                let path=UIBezierPath();var started=false
                for uv in points {if let p=point(uv) {if started {path.addLine(to:p)} else {path.move(to:p);started=true}}}
                color.setStroke();path.lineWidth=width;path.stroke()
            }
            for i in 1...7 {
                let a=Double(i)/8
                stroke((0...40).map{SIMD2(a,Double($0)/40)},color:UIColor(white:0.3,alpha:1),width:1)
                stroke((0...40).map{SIMD2(Double($0)/40,a)},color:UIColor(white:0.3,alpha:1),width:1)
            }
            stroke((0...96).map {i in let a=Double(i)*2*Double.pi/96;return SIMD2(0.5+cos(a)*0.12/aspect,0.5+sin(a)*0.12)},color:.cyan,width:2)
            stroke([SIMD2(0.46,0.5),SIMD2(0.54,0.5)],color:.white,width:3)
            stroke([SIMD2(0.5,0.46),SIMD2(0.5,0.54)],color:.white,width:3)
            if let center=point(SIMD2(0.5,0.5)) {UIColor.white.setFill();UIBezierPath(ovalIn:CGRect(x:center.x-2,y:center.y-2,width:4,height:4)).fill()}
            context.restoreGState()
        }
    }
}
