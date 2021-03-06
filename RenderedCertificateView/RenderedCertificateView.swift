//
//  RCView.swift
//  cert-wallet
//
//  Created by Chris Downie on 8/23/16.
//  Copyright © 2016 Digital Certificates Project. All rights reserved.
//

import UIKit

class RenderedCertificateView: UIView {

    @IBOutlet var view: UIView!
    
    @IBOutlet weak var paperView: UIView!
    
    @IBOutlet weak var nameLabel: UILabel!
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var subtitleLabel: UILabel!
    @IBOutlet weak var descriptionLabel: UILabel!
    
    @IBOutlet weak var certificateIcon: UIImageView!
    
    @IBOutlet weak var signatureStack: UIStackView!
    
    @IBOutlet weak var sealIcon: UIImageView!

    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        commonInit()
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        
        commonInit()
    }
    
    func commonInit() {
        Bundle.main.loadNibNamed("RenderedCertificateView", owner: self, options: nil)
        styleize()
        addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        
        addConstraint(NSLayoutConstraint(item: view, attribute: .top, relatedBy: NSLayoutRelation.equal, toItem: self, attribute: .top, multiplier: 1, constant: 0))
        addConstraint(NSLayoutConstraint(item: view, attribute: .bottom, relatedBy: NSLayoutRelation.equal, toItem: self, attribute: .bottom, multiplier: 1, constant: 0))
        addConstraint(NSLayoutConstraint(item: view, attribute: .left, relatedBy: NSLayoutRelation.equal, toItem: self, attribute: .left, multiplier: 1, constant: 0))
        addConstraint(NSLayoutConstraint(item: view, attribute: .right, relatedBy: NSLayoutRelation.equal, toItem: self, attribute: .right, multiplier: 1, constant: 0))
        
    }
    
    private func styleize() {
    }
    
    func clearSignatures() {
        signatureStack.subviews.forEach { (view) in
            view.removeFromSuperview()
        }
    }
    
    func addSignature(image: UIImage, title: String?) {
        if title == nil {
            let subview = UIImageView(image: image)
            signatureStack.addArrangedSubview(subview)
        } else {
            let subview = createTitledSignature(signature: image, title: title!)
            signatureStack.addArrangedSubview(subview)
        }
        updateConstraints()
    }
    
    func createTitledSignature(signature: UIImage, title titleString: String) -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        
        // Configure all the subviews
        let signature = UIImageView(image: signature)
        signature.contentMode = .scaleAspectFit
        signature.translatesAutoresizingMaskIntoConstraints = false
        
        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = UIFont.systemFont(ofSize: 11)
        title.text = titleString
        
        view.addSubview(signature)
        view.addSubview(title)

        
        // Now do all the auto-layout.
        let namedViews = [
            "signature": signature,
            "title": title
        ]
        let verticalConstraints = NSLayoutConstraint.constraints(withVisualFormat: "V:|[signature]-[title]|", options: .alignAllCenterX, metrics: nil, views: namedViews)
        let maxWidth : CGFloat = 150
        var signatureConstraints = [
            NSLayoutConstraint(item: signature, attribute: .width, relatedBy: .lessThanOrEqual, toItem: nil, attribute: .notAnAttribute, multiplier: 0, constant: maxWidth)
        ]
        if signature.bounds.width > maxWidth {
            let expectedHeight = signature.bounds.height * maxWidth / signature.bounds.width
            signatureConstraints.append(NSLayoutConstraint(item: signature, attribute: .height, relatedBy: .lessThanOrEqual, toItem: nil, attribute: .notAnAttribute, multiplier: 0, constant: expectedHeight))
        }
        let centerConstraints = [
            NSLayoutConstraint(item: signature, attribute: .centerX, relatedBy: .equal, toItem: view, attribute: .centerX, multiplier: 1, constant: 0)
        ]

        NSLayoutConstraint.activate(signatureConstraints)
        NSLayoutConstraint.activate(verticalConstraints)
        NSLayoutConstraint.activate(centerConstraints)
        
        return view
    }
}
